import hxmc.objc.AutoreleasePool;
import hxmc.objc.Selector;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// protocols: extern interfaces, their optional methods `default` ones (a
// class implementing the protocol may leave them out: Objective-C then
// sees no such method, respondsToSelector: says no)

@:hxmc.objc("NSObject") extern interface NSObjectProtocol {
	function respondsToSelector(sel:Selector):Bool;
	function conformsToProtocol(p:Ptr):Bool;
}

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements NSObjectProtocol {
	static function alloc():NSObject;
	function init():NSObject;
	function respondsToSelector(sel:Selector):Bool;
	function conformsToProtocol(p:Ptr):Bool;
	function isEqual(o:NSObject):Bool;
	function hash():Int64;
	function retainCount():Int64;
}

@:hxmc.objc extern interface NSCopying {
	function copyWithZone(zone:Ptr):NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSData extends NSObject {
	static function dataWithBytes(bytes:CString, length:Int64):NSData;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableDictionary extends NSObject {
	static function alloc():NSMutableDictionary;
	override function init():NSMutableDictionary;
	function setObject(o:NSObject, forKey:NSCopying):Void;
	function objectForKey(key:NSObject):NSObject;
}

@:hxmc.objc extern interface NSXMLParserDelegate extends NSObjectProtocol {
	@:selector("parserDidStartDocument:") @:optional function parserDidStartDocument(parser:NSXMLParser):Void;
	@:selector("parserDidEndDocument:") @:optional function parserDidEndDocument(parser:NSXMLParser):Void;
	@:selector("parser:didStartElement:namespaceURI:qualifiedName:attributes:") @:optional function didStartElement(parser:NSXMLParser, name:NSString,
		ns:NSString, qName:NSString, attributes:NSObject):Void;
	@:selector("parser:didEndElement:namespaceURI:qualifiedName:") @:optional function didEndElement(parser:NSXMLParser, name:NSString, ns:NSString,
		qName:NSString):Void;
	@:selector("parser:foundCharacters:") @:optional function foundCharacters(parser:NSXMLParser, s:NSString):Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSXMLParser extends NSObject {
	static function alloc():NSXMLParser;
	function initWithData(data:NSData):NSXMLParser;
	var delegate(get, set):Null<NSXMLParserDelegate>;
	function get_delegate():Null<NSXMLParserDelegate>;
	function set_delegate(d:Null<NSXMLParserDelegate>):Null<NSXMLParserDelegate>;
	function parse():Bool;
}

// a delegate implementing some of the optional methods
class Collector extends NSObject implements NSXMLParserDelegate {
	public var log:Array<String> = [];

	public function new() {}

	public function parserDidStartDocument(parser:NSXMLParser)
		log.push("start");

	public function didStartElement(parser:NSXMLParser, name:NSString, ns:NSString, qName:NSString, attributes:NSObject)
		log.push("<" + Strings.ofNSString(cast name) + ">");

	public function foundCharacters(parser:NSXMLParser, s:NSString)
		log.push(Strings.ofNSString(cast s));
}

// a subclass implementing an optional method its superclass left out
class LateCollector extends Collector {
	override public function parserDidEndDocument(parser:NSXMLParser)
		log.push("end");
}

// a key Foundation copies (NSDictionary copies its keys: copyWithZone:,
// whose result is the caller's, retained)
class Key extends NSObject implements NSCopying {
	public static var copies = 0;

	public var name:String;

	public function new(name:String)
		this.name = name;

	public function copyWithZone(zone:Ptr):NSObject {
		copies++;
		return new Key(name);
	}

	override function isEqual(o:NSObject):Bool {
		var k = Std.downcast((cast o : Key), Key);
		return k != null && k.name == name;
	}

	override function hash():Int64
		return name.length;
}

// a protocol no image declares (made at run time), with a property
@:hxmc.objc("HxmcCounting") extern interface Counting {
	var count(get, never):Int64;
	function get_count():Int64;
	function bump(by:Int64):Int64;
	// (an optional property: its accessors too)
	@:optional var label(get, never):NSString;
	@:optional function get_label():NSString;
}

class Counter extends NSObject implements Counting {
	var n:Int64 = 0;

	public var count(get, never):Int64;

	public function new() {}

	public function get_count():Int64
		return n;

	public function bump(by:Int64):Int64
		return n += by;
}

// a copy of its own type (the method's result a subtype of the protocol's)
class Twin extends NSObject implements NSCopying {
	public static var gone = 0;

	public var name:String;

	public function new(name:String)
		this.name = name;

	public function copyWithZone(zone:Ptr):Twin
		return new Twin(name + "+");
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	static function arrayWithObject(o:NSObject):NSArray;
	function copy():NSArray;
	function objectAtIndex(i:Int64):NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSArray {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	@:selector("initWithArray:copyItems:") function initWithArrayCopyItems(a:NSArray, copyItems:Bool):NSMutableArray;
}

class ObjCProtocols {
	static function main() AutoreleasePool.run(() -> {
		var c = new Collector();
		var asObj:NSObject = c;
		trace("responds: " + asObj.respondsToSelector(Selector.of("parser:didStartElement:namespaceURI:qualifiedName:attributes:")) + " "
			+ asObj.respondsToSelector(Selector.of("parser:foundCharacters:")) + " "
			+ asObj.respondsToSelector(Selector.of("parser:didEndElement:namespaceURI:qualifiedName:")) + " "
			+ asObj.respondsToSelector(Selector.of("parserDidEndDocument:")));

		var xml = "<a>one<b>two</b></a>";
		var parser = NSXMLParser.alloc().initWithData(NSData.dataWithBytes(cast Mem.cstr("<a>one<b>two</b></a>"), xml.length));
		parser.delegate = c;
		trace("parse: " + parser.parse() + " " + c.log);

		var late = new LateCollector();
		var p2 = NSXMLParser.alloc().initWithData(NSData.dataWithBytes(cast Mem.cstr("<a>one<b>two</b></a>"), xml.length));
		p2.delegate = late;
		p2.parse();
		var asCollector:Collector = late;
		asCollector.parserDidEndDocument(p2);
		trace("subclass: " + late.log + " " + (late : NSObject).respondsToSelector(Selector.of("parserDidEndDocument:")));

		// a protocol's value: an id, the same object again
		var d:NSXMLParserDelegate = parser.delegate;
		trace("delegate: " + (d == (c : NSXMLParserDelegate)) + " " + (cast d == c));
		d.parserDidStartDocument(parser);
		trace("through the protocol: " + c.log.length);

		// conformance (the protocol and those it extends), Std.isOfType's test
		trace("conforms: " + Std.isOfType(asObj, NSXMLParserDelegate) + " " + Std.isOfType(asObj, NSObjectProtocol) + " " + Std.isOfType(asObj, NSCopying)
			+ " " + Std.isOfType(NSObject.alloc().init(), NSXMLParserDelegate));
		var down = Std.downcast((asObj : NSObjectProtocol), NSXMLParserDelegate);
		trace("downcast: " + (down != null) + " " + (Std.downcast((NSObject.alloc().init() : NSObjectProtocol), NSXMLParserDelegate) == null));

		// Foundation calling a Haxe copyWithZone:
		var dict = NSMutableDictionary.alloc().init();
		var k = new Key("k");
		dict.setObject(cast Strings.toNSString("value"), k);
		trace("copies: " + Key.copies);
		for (_ in 0...2)
			hxmc.rt.Gc.collect(true);
		trace("lookup: " + Strings.ofNSString(cast dict.objectForKey(k)));

		// a protocol made at run time: conformance, messages and a property through it
		var counter = new Counter();
		var counting:Counting = counter;
		counting.bump(2);
		counting.bump(3);
		trace("own protocol: " + counting.count + " " + Std.isOfType((counter : NSObject), Counting) + " " + Std.isOfType(NSObject.alloc().init(), Counting)
			+ " " + (counter : NSObject).respondsToSelector(Selector.of("label")));

		// Foundation copying Haxe objects (copyItems: copyWithZone:, a subtype's
		// result, which the array owns: released when it goes, then collected)
		var twins = [];
		AutoreleasePool.run(() -> {
			for (i in 0...100) {
				var copied = NSMutableArray.alloc().initWithArrayCopyItems(NSArray.arrayWithObject(new Twin("t" + i)), true);
				var twin = Std.downcast((cast copied.objectAtIndex(0) : Twin), Twin);
				twins.push(twin.name);
				hxmc.rt.Gc.finalise(_ -> Twin.gone++, twin);
			}
			hxmc.rt.Gc.collect(true);
		});
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.runFinalisers();
		trace("twins: " + twins[0] + " " + twins[99] + ", collected " + Twin.gone);
		// (one kept past the array: Haxe's own reference to it is still there)
		var kept:Twin = null;
		AutoreleasePool.run(() -> {
			var copied = NSMutableArray.alloc().initWithArrayCopyItems(NSArray.arrayWithObject(new Twin("k")), true);
			kept = Std.downcast((cast copied.objectAtIndex(0) : Twin), Twin);
		});
		for (_ in 0...2)
			hxmc.rt.Gc.collect(true);
		AutoreleasePool.run(() -> trace("kept: " + kept.name + " " + (kept : NSObject).isEqual(kept)));

		// classes: isKindOfClass:
		var arr:NSObject = NSArray.arrayWithObject(asObj);
		trace("kind: " + Std.isOfType(arr, NSArray) + " " + Std.isOfType(arr, NSMutableArray) + " " + Std.isOfType(asObj, NSObject) + " "
			+ (Std.downcast(arr, NSArray) != null) + " " + (Std.downcast(arr, NSXMLParser) == null));
	});
}
