package generators.jvm;

import generators.jvm.JvmGlobals;
import generators.jvm.JvmSignature;
import generators.jvm.JvmSignature.NativeSignatures.*;
import generators.jvm.JvmClass;
import generators.jvm.JvmMethod;

enum SignatureClassification {
	CBool;
	CByte;
	CChar;
	CShort;
	CInt;
	CLong;
	CFloat;
	CDouble;
	CObject;
}

@:structInit class MethodSignature {
	public final arity:Int;
	public final name:String;
	public final hasNonobject:Bool;
	public final sortString:String;
	public final cargs:Array<SignatureClassification>;
	public final cret:Null<SignatureClassification>;
	public final dargs:Array<JSignature>;
	public final dret:Null<JSignature>;
	public var next:Null<MethodSignature>;
}

enum TypedFunctionKind {
	FuncLocal(s:Null<String>);
	FuncMember(path:JPath, name:String);
	FuncStatic(path:JPath, name:String);
}

/* A typed_function lives either as an inner class of its caller (THostInner
   — the default for locals and most member/static cases) or as a standalone
   top-level class at a caller-independent path (THostStandalone — used by
   the shared field-closure pool, see gctx.closure_paths in genjvm.ml). */
enum TypedFunctionHost {
	THostInner(c:JvmClassBuilder);
	THostStandalone(path:JPath);
}

@:structInit class JavaFunctionalInterface {
	public final jargs:Array<JSignature>;
	public final jret:Null<JSignature>;
	public final jpath:JPath;
	public final jname:String;
	public final jparams:Array<String>;

	public static function stringOfFunctionalInterface(jfi:JavaFunctionalInterface):String {
		return core.TPrinting.Printer.sRecordFields("", [
			{name: "jargs", value: jfi.jargs.map(JvmSignature.generateSignature.bind(true)).join(", ")},
			{name: "jret", value: jfi.jret == null ? "None" : JvmSignature.generateSignature(true, jfi.jret)},
			{name: "jpath", value: core.Globals.sTypePath({pack: jfi.jpath.pack, name: jfi.jpath.name})},
			{name: "jname", value: jfi.jname},
			{name: "jparams", value: jfi.jparams.join(", ")},
		]);
	}

	public static function create(args:Array<JSignature>, ret:Null<JSignature>, path:JPath, name:String,
			params:Array<String>):JavaFunctionalInterface {
		var jfi:JavaFunctionalInterface = {
			jargs: args,
			jret: ret,
			jpath: path,
			jname: name,
			jparams: params,
		};
		return jfi;
	}
}

class JvmFunctions {
	public static function stringOfClassification(c:SignatureClassification):String return switch c {
		case CByte: "Byte";
		case CChar: "Char";
		case CDouble: "Double";
		case CFloat: "Float";
		case CInt: "Int";
		case CLong: "Long";
		case CShort: "Short";
		case CBool: "Bool";
		case CObject: "Object";
	}

	public static function classify(s:JSignature):SignatureClassification return switch s {
		case JByte: CByte;
		case JChar: CChar;
		case JDouble: CDouble;
		case JFloat: CFloat;
		case JInt: CInt;
		case JLong: CLong;
		case JShort: CShort;
		case JBool: CBool;
		case JObject(_) | JObjectInner(_) | JArray(_) | JMethod(_) | JTypeParameter(_) | JUninitialized(_): CObject;
	}

	public static function declassify(c:SignatureClassification):JSignature return switch c {
		case CByte: JByte;
		case CChar: JChar;
		case CDouble: JDouble;
		case CFloat: JFloat;
		case CInt: JInt;
		case CLong: JLong;
		case CShort: JShort;
		case CBool: JBool;
		case CObject: objectPathSig(objectPath);
	}
}

class TypedFunctions {
	final signatureMutex = new sys.thread.Mutex();
	// port: keyed by `(cl,cr)`; only used for lookups and a fold that is sorted afterwards.
	final signatures:haxe.ds.StringMap<MethodSignature> = new haxe.ds.StringMap();
	var maxArity = 0;

	public function new() {}

	static function sigKey(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):String {
		return [for (c in cl) c.getIndex()].join(",") + ":" + (cr == null ? "-" : Std.string(cr.getIndex()));
	}

	public function registerSignature(tl:Array<JSignature>, tr:Null<JSignature>):MethodSignature {
		var cl = tl.map(JvmFunctions.classify);
		var cr = tr == null ? null : JvmFunctions.classify(tr);
		return getSignature(cl, cr);
	}

	public function objectify(meth:MethodSignature):MethodSignature {
		var clObjects = meth.cargs.map(function(_) return CObject);
		return getSignature(clObjects, meth.cret);
	}

	function getSignature(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):MethodSignature {
		signatureMutex.acquire();
		var meth = signatures.get(sigKey(cl, cr));
		if (meth == null) meth = doRegisterSignature(cl, cr);
		signatureMutex.release();
		/* If the method has something that's not java.lang.Object, the next method is one where all arguments are
			 of type java.lang.Object. */
		if (meth.hasNonobject) {
			var methObjects = objectify(meth);
			meth.next = methObjects;
			/* Otherwise, if the method has a return type that's not java.lang.Object, the next method is one that returns
				 java.lang.Object. */
		} else {
			switch cr {
				case CObject:
				case _:
					meth.next = getSignature(meth.cargs, CObject);
			}
		}
		return meth;
	}

	function doRegisterSignature(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):MethodSignature {
		function toString(cl:Array<SignatureClassification>, cr:Null<SignatureClassification>):String {
			return "[" + cl.map(JvmFunctions.stringOfClassification).join(", ") + "] "
				+ (cr == null ? "CVoid" : JvmFunctions.stringOfClassification(cr));
		}
		var meth:MethodSignature = {
			arity: cl.length,
			name: "invoke",
			hasNonobject: Lambda.exists(cl, function(c) return switch c {
				case CObject: false;
				case _: true;
			}),
			sortString: toString(cl, cr),
			cargs: cl,
			cret: cr,
			dargs: cl.map(JvmFunctions.declassify),
			dret: cr == null ? null : JvmFunctions.declassify(cr),
			next: null,
		};
		if (meth.arity > maxArity) maxArity = meth.arity;
		signatures.set(sigKey(meth.cargs, meth.cret), meth);
		return meth;
	}

	public function makeForwardMethodJsig(jc:JvmClassBuilder, jm:JvmMethodBuilder, name:String, argsFrom:Array<JSignature>, retFrom:Null<JSignature>,
			argsTo:Array<JSignature>, retTo:Null<JSignature>):Void {
		var args = [for (i in 0...argsFrom.length) jm.addLocal('arg$i', argsFrom[i], VarArgument)];
		jm.finalizeArguments();
		jm.loadThis();
		var li = 0;
		for (jsig in argsTo) {
			if (li < args.length) {
				args[li++].load();
				jm.cast_(jsig);
			} else {
				jm.loadDefaultValue(jsig);
			}
		}
		if (li < args.length) core.Globals.die("", "generators/jvm/jvmFunctions.ml");
		jm.invokevirtual(jc.getThisPath(), name, methodSig(argsTo, retTo));
		switch [retFrom, retTo] {
			case [null, null]:
			case [jsig, _] if (jsig != null && retTo != null):
				jm.cast_(jsig);
			case [null, jsig]:
				jm.getCode().pop();
			case [jsig, _]:
				jm.loadDefaultValue(jsig);
		}
		jm.return_();
	}

	public function makeForwardMethod(jc:JvmClassBuilder, jm:JvmMethodBuilder, methFrom:MethodSignature, methTo:MethodSignature):Void {
		makeForwardMethodJsig(jc, jm, methTo.name, methFrom.dargs, methFrom.dret, methTo.dargs, methTo.dret);
	}

	public function generateInvokeDynamic(jc:JvmClassBuilder):Void {
		var arraySig = JArray(objectSig, null);
		var jm = jc.spawnMethod("invokeDynamic", methodSig([arraySig], objectSig), [MPublic]);
		var load = jm.addLocal("args", arraySig, VarArgument).load;
		jm.finalizeArguments();
		load();
		jm.getCode().arraylength(arraySig);
		var cases = [
			for (i in 0...maxArity + 1)
				{
					il: [i],
					f: function() {
						jm.loadThis();
						var args = [
							for (index in 0...i) {
								load();
								jm.getCode().iconst(index);
								jm.getCode().aaload(arraySig, objectSig);
								objectSig;
							}
						];
						jm.invokevirtual(jc.getThisPath(), "invoke", methodSig(args, objectSig));
						jm.return_();
					}
				}
		];
		var def = function() {
			jm.construct(ConstructInit, {pack: ["java", "lang"], name: "IllegalArgumentException"}, function() return []);
			jm.getCode().athrow();
			jm.setTerminated(true);
		};
		jm.intSwitch(true, cases, def);
	}

	public function generateClosureDispatch():JvmClassBuilder {
		var jc = new JvmClassBuilder({pack: ["haxe", "jvm"], name: "ClosureDispatch"}, haxeFunctionPath);
		jc.addAccessFlag(1); /* public */
		var jmCtor = jc.spawnMethod("<init>", methodSig([], null), [MPublic]);
		jmCtor.finalizeArguments();
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, methodSig([], null));
		jmCtor.return_();
		function loop(args:Array<JSignature>, i:Int):Void {
			var jsig = methodSig(args, objectSig);
			var jm = jc.spawnMethod("invoke", jsig, [MPublic]);
			var vars = [for (i in 0...i) jm.addLocal('arg$i', objectSig, VarArgument)];
			jm.loadThis();
			jm.newNativeArray(objectSig, vars.map(function(v) return function() v.load()));
			jm.invokevirtual(haxeFunctionPath, "invokeDynamic", methodSig([arraySig(objectSig)], objectSig));
			jm.return_();
			if (i < maxArity) loop([objectSig].concat(args), i + 1);
		}
		loop([], 0);
		return jc;
	}

	public function generateVarArgs():JvmClassBuilder {
		var jc = new JvmClassBuilder({pack: ["haxe", "jvm"], name: "VarArgs"}, haxeFunctionPath);
		jc.addAccessFlag(1); /* public */
		var jmCtor = jc.spawnMethod("<init>", methodSig([haxeFunctionSig], null), [MPublic]);
		jmCtor.addArgumentAndField("func", haxeFunctionSig, [FdPublic, FdFinal]);
		jmCtor.finalizeArguments();
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, methodSig([], null));
		jmCtor.return_();
		function loop(args:Array<JSignature>, i:Int):Void {
			var jsig = methodSig(args, objectSig);
			var jm = jc.spawnMethod("invoke", jsig, [MPublic, MBridge, MSynthetic]);
			var vars = [for (i in 0...i) jm.addLocal('arg$i', objectSig, VarArgument)];
			jm.loadThis();
			jm.getfield(jc.getThisPath(), "func", haxeFunctionSig);
			jm.newNativeArray(objectSig, vars.map(function(v) return function() v.load()));
			jm.invokestatic({pack: ["haxe", "root"], name: "Array"}, "ofNative",
				methodSig([arraySig(objectSig)], objectPathSig({pack: ["haxe", "root"], name: "Array"})));
			jm.invokevirtual(haxeFunctionPath, "invoke", methodSig([objectSig], objectSig));
			jm.return_();
			if (i < maxArity) loop([objectSig].concat(args), i + 1);
		}
		loop([], 0);
		return jc;
	}

	public function generate():JvmClassBuilder {
		var l = [for (v in signatures) v];
		l.sort(function(meth1, meth2) {
			if (meth1.arity != meth2.arity) return meth1.arity < meth2.arity ? -1 : 1;
			return core.ds.Key.compareStrings(meth1.sortString, meth2.sortString);
		});
		var jc = new JvmClassBuilder(haxeFunctionPath, objectPath);
		jc.addAccessFlag(1); /* public */
		for (meth in l) {
			var jm = jc.spawnMethod(meth.name, methodSig(meth.dargs, meth.dret), [MPublic, MBridge, MSynthetic]);
			switch meth.next {
				case null if (meth.arity < maxArity && !meth.hasNonobject):
					var methNext = getSignature([CObject].concat(meth.cargs), meth.cret);
					makeForwardMethod(jc, jm, meth, methNext);
				case null:
					for (i in 0...meth.dargs.length) jm.addLocal('arg$i', meth.dargs[i], VarArgument);
					jm.finalizeArguments();
					switch meth.dret {
						case null:
						case jsig: jm.loadDefaultValue(jsig);
					}
					jm.return_();
				case methNext:
					makeForwardMethod(jc, jm, meth, methNext);
			}
		}
		var jmCtor = jc.spawnMethod("<init>", methodSig([], null), [MPublic]);
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, methodSig([], null));
		jmCtor.return_();
		generateInvokeDynamic(jc);
		return jc;
	}
}

class TypedFunction {
	final functions:TypedFunctions;
	final kind:TypedFunctionKind;
	final host:TypedFunctionHost;
	final hostMethod:JvmMethodBuilder;
	final context:Array<{name:String, jsig:JSignature}>;

	// port: OCaml list built by prepending; index 0 is the head.
	var functionalInterfaces:Array<{jfi:JavaFunctionalInterface, params:Array<JTypeArgument>}> = [];

	final jcClosure:JvmClassBuilder;

	public function new(functions:TypedFunctions, kind:TypedFunctionKind, host:TypedFunctionHost, hostMethod:JvmMethodBuilder,
			context:Array<{name:String, jsig:JSignature}>) {
		this.functions = functions;
		this.kind = kind;
		this.host = host;
		this.hostMethod = hostMethod;
		this.context = context;
		var jc = switch host {
			case THostInner(hostClass):
				var name = switch kind {
					case FuncLocal(s):
						var name = JvmGlobals.patchName(hostMethod.getName());
						var name = switch s {
							case null: name;
							case s: name + "_" + s;
						}
						'Closure_${name}_${hostClass.getNextClosureId(name)}';
					case FuncStatic(path, name) | FuncMember(path, name):
						var prefix = switch path.pack {
							case []: path.name;
							case pkg: pkg.join("_") + "_" + path.name;
						}
						'${prefix}_${JvmGlobals.patchName(name)}';
				}
				hostClass.spawnInnerClass(null, haxeFunctionPath, name);
			case THostStandalone(path):
				var jc = new JvmClassBuilder(path, haxeFunctionPath);
				jc.addAccessFlag(0x01); /* public */
				jc;
		}
		jc.addTypedFunction(jc.getThisPath());
		jc.addAccessFlag(0x10); /* final */
		jcClosure = jc;
	}

	public function getClass():JvmClassBuilder return jcClosure;

	public function generateConstructor(isPublic:Bool):JvmMethodBuilder {
		var contextSigs = context.map(function(c) return c.jsig);
		var jmCtor = jcClosure.spawnMethod("<init>", methodSig(contextSigs, null), if (isPublic) [MPublic] else []);
		for (c in context) jmCtor.addArgumentAndField(c.name, c.jsig, [FdPublic, FdFinal]);
		jmCtor.loadThis();
		jmCtor.callSuperCtor(ConstructInit, methodSig([], null));
		jmCtor.return_();
		return jmCtor;
	}

	public function addFunctionalInterface(jfi:JavaFunctionalInterface, params:Array<JSignature>):Void {
		var params = params.map(function(jsig) return JTType(WNone, jsig));
		functionalInterfaces.unshift({jfi: jfi, params: params});
	}

	public function generateInvoke(args:Array<{name:String, jsig:JSignature}>, ret:Null<JSignature>, functionalInterfaceFilter:Array<JPath>):JvmMethodBuilder {
		var argSigs = args.map(function(a) return a.jsig);
		var meth = functions.registerSignature(argSigs, ret);
		var jsigInvoke = methodSig(argSigs, ret);
		var jmInvoke = jcClosure.spawnMethod(meth.name, jsigInvoke, [MPublic]);
		var implementedInterfaces = new haxe.ds.StringMap<Bool>();
		function addInterface(path:JPath, params:Array<JTypeArgument>):Void {
			var key = path.pack.join("/") + "/" + path.name;
			if (!implementedInterfaces.exists(key)) {
				jcClosure.addInterface(path, params);
				implementedInterfaces.set(key, true);
			}
		}
		function spawnInvokeNext(name:String, msig:JSignature, isBridge:Bool):JvmMethodBuilder {
			var flags = [MPublic];
			var flags = if (isBridge) [MBridge, MSynthetic].concat(flags) else flags;
			return jcClosure.spawnMethod(name, msig, flags);
		}
		function spawnForwardFunction(methFrom:MethodSignature, methTo:MethodSignature, isBridge:Bool):Void {
			var msig = methodSig(methFrom.dargs, methFrom.dret);
			if (!jcClosure.hasMethod(methFrom.name, msig)) {
				var jmInvokeNext = spawnInvokeNext(methFrom.name, msig, isBridge);
				functions.makeForwardMethod(jcClosure, jmInvokeNext, methFrom, methTo);
			}
		}
		for (e in functionalInterfaces) {
			var jfi = e.jfi;
			addInterface(jfi.jpath, e.params);
			var msig = methodSig(jfi.jargs, jfi.jret);
			if (!jcClosure.hasMethod(jfi.jname, msig)) {
				var jmInvokeNext = spawnInvokeNext(jfi.jname, msig, false);
				/* Forward to the typed invoke (arg_sigs, ret) rather than the
					 Object-declassified (meth.dargs, meth.dret). When the FI's
					 own method is also named "invoke" with an erased Object
					 return (Function0<T>, Callable<V>, …), forwarding to
					 meth.dret would emit `invokevirtual invoke()Object` against
					 this very bridge and self-recurse — the later loop that
					 would have synthesized the Object→typed bridge is then
					 short-circuited by has_method. */
				functions.makeForwardMethodJsig(jcClosure, jmInvokeNext, meth.name, jfi.jargs, jfi.jret, argSigs, ret);
			}
		}
		function loop(meth:MethodSignature):Void {
			switch meth.next {
				case null:
				case methNext:
					spawnForwardFunction(methNext, meth, true);
					loop(methNext);
			}
		}
		var returnDiffers = switch [meth.dret, ret] {
			case [null, null]: false;
			case [jsig1, jsig2] if (jsig1 != null && jsig2 != null): !JvmSignature.equalsAtRuntime(jsig1, jsig2);
			case _: true;
		}
		// port: List.for_all2 raises Invalid_argument on lists of different lengths
		if (meth.dargs.length != argSigs.length) throw new core.ds.InvalidArgument("List.for_all2");
		var allEqual = true;
		for (i in 0...argSigs.length) if (!JvmSignature.equalsAtRuntime(meth.dargs[i], argSigs[i])) {
			allEqual = false;
			break;
		}
		var meth = if (!allEqual || returnDiffers) {
			var methPrev = meth;
			var meth:MethodSignature = {
				arity: meth.arity,
				name: meth.name,
				hasNonobject: meth.hasNonobject,
				sortString: meth.sortString,
				cargs: meth.cargs,
				cret: meth.cret,
				dargs: argSigs,
				dret: ret,
				next: meth.next
			};
			meth.next = methPrev;
			meth;
		} else meth;
		loop(meth);
		return jmInvoke;
	}
}
