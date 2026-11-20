package macros.eval;

import macros.eval.EvalValue;

// port: the modules are classes with static functions.
class EvalReaderApi {
	public static function readOptional(v:Value, f:Value->Void):Void {
		switch v {
			case VNull:
			case _:
				f(v);
		}
	}

	public static function readObject(v:Value):Array<{name:String, value:Value}> {
		return EvalContext.objectFields(EvalDecode.decodeObject(v)).map(f -> {name: EvalHash.revHash(f.name), value: f.value});
	}

	public static function readArray(v:Value):Array<Value> return EvalArray.toList(EvalDecode.decodeVarray(v));

	public static function readString(v:Value):String return EvalDecode.decodeString(v);

	public static function readIdent(v:Value):String return EvalDecode.decodeString(v);

	public static function readInt(v:Value):Int return EvalDecode.decodeInt(v);

	public static function readBool(v:Value):Bool return EvalDecode.decodeBool(v);

	public static function dataToString(v:Value):String return EvalPrinting.sValue(0, v).sstring;

	public static function api():core.data.DataReaderApi<Value> {
		return new core.data.DataReaderApi(readOptional, readObject, readArray, readString, readIdent, readBool, readInt, dataToString);
	}
}

class EvalWriterApi {
	public static function writeOptional(vo:Null<Value>):Value {
		return switch vo {
			case null: VNull;
			case v: v;
		}
	}

	public static function writeObject(fl:Array<{name:String, value:Value}>):Value {
		return EvalEncode.encodeObj(fl.map(f -> {name: EvalHash.hash(f.name), value: f.value}));
	}

	public static function writeArray(vl:Array<Value>):Value return EvalEncode.encodeArray(vl);

	public static function writeString(s:String):Value return EvalEncode.encodeString(s);

	public static function writeBool(b:Bool):Value return b ? VTrue : VFalse;

	public static function writeInt(i:Int):Value return VInt(i);

	public static function api():core.data.DataWriterApi<Value> {
		return new core.data.DataWriterApi(writeOptional, writeObject, writeArray, writeString, writeBool, writeInt);
	}
}

class EvalDataApi {}
