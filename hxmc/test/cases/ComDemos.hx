import hxmc.com.*;
import hxmc.unsafe.*;

// The system's COM objects (docs/interop.md, "COM"; Windows only), headless:
// the file open dialog made, its options, title, file name, file types and
// folder set and read back (Show is interactive: not called), its
// interfaces queried, and a Haxe object as its events' sink (Advise, its
// count, Unadvise); DirectWrite's factory (a C function's [out] interface), a
// text format and a layout measured.
@:hxmc.com("{b4db1657-70d7-485e-8e3e-6fcb5a5c1802}")
extern interface IModalWindow extends IUnknown {
	@:hxmc.com.hresult function Show(owner:Ptr):Int;
}

@:hxmc.com("{43826d1e-e718-42ee-bc55-a1e261c37bfe}")
extern interface IShellItem extends IUnknown {
	function BindToHandler(bc:Ptr, bhid:Ptr, riid:Ptr, out:Ptr):Void;
	function GetParent():IShellItem;
	function GetDisplayName(sigdn:Int):String;
	function GetAttributes(mask:Int):Int;
	function Compare(other:IShellItem, hint:Int):Int;
}

@:hxmc.com("{973510db-7d7f-452b-8975-74a85828d354}")
extern interface IFileDialogEvents extends IUnknown {
	function OnFileOk(dialog:IFileDialog):Void;
	function OnFolderChanging(dialog:IFileDialog, folder:IShellItem):Void;
	function OnFolderChange(dialog:IFileDialog):Void;
	function OnSelectionChange(dialog:IFileDialog):Void;
	function OnShareViolation(dialog:IFileDialog, item:IShellItem, response:Ptr<Int32>):Void;
	function OnTypeChange(dialog:IFileDialog):Void;
	function OnOverwrite(dialog:IFileDialog, item:IShellItem, response:Ptr<Int32>):Void;
}

@:hxmc.com("{42f85136-db7e-439c-85f1-e4075d135fc8}")
extern interface IFileDialog extends IModalWindow {
	function SetFileTypes(n:Int, specs:Ptr):Void;
	function SetFileTypeIndex(i:Int):Void;
	function GetFileTypeIndex():Int;
	function Advise(sink:IFileDialogEvents):Int;
	function Unadvise(cookie:Int):Void;
	function SetOptions(options:Int):Void;
	function GetOptions():Int;
	function SetDefaultFolder(item:IShellItem):Void;
	function SetFolder(item:IShellItem):Void;
	function GetFolder():IShellItem;
	function GetCurrentSelection():IShellItem;
	function SetFileName(name:String):Void;
	function GetFileName():String;
	function SetTitle(title:String):Void;
	function SetOkButtonLabel(label:String):Void;
	function SetFileNameLabel(label:String):Void;
	function GetResult():IShellItem;
	function AddPlace(item:IShellItem, where:Int):Void;
	function SetDefaultExtension(ext:String):Void;
	function Close(hr:Int):Void;
	function SetClientGuid(guid:Ptr):Void;
	function ClearClientData():Void;
	function SetFilter(filter:Ptr):Void;
}

@:hxmc.com("{d57c7288-d4ad-4768-be02-9d969532d960}")
extern interface IFileOpenDialog extends IFileDialog {
	function GetResults():IUnknown;
	function GetSelectedItems():IUnknown;
}

@:hxmc.c @:hxmc.lib("shell32") extern class Shell32 {
	static function SHCreateItemFromParsingName(path:Ptr, bc:Ptr, riid:Ptr, out:Ptr):Int;
}

// DirectWrite
@:hxmc.struct class TextMetrics {
	public var left:Float32;
	public var top:Float32;
	public var width:Float32;
	public var widthIncludingTrailingWhitespace:Float32;
	public var height:Float32;
	public var layoutWidth:Float32;
	public var layoutHeight:Float32;
	public var maxBidiReorderingDepth:UInt32;
	public var lineCount:UInt32;

	public function new() {}
}

@:hxmc.com("{9c906818-31d7-4fd3-a151-7c5e225db55a}")
extern interface IDWriteTextFormat extends IUnknown {
	function SetTextAlignment(a:Int):Void;
	function SetParagraphAlignment(a:Int):Void;
	function SetWordWrapping(w:Int):Void;
	function SetReadingDirection(d:Int):Void;
	function SetFlowDirection(d:Int):Void;
	function SetIncrementalTabStop(t:Float32):Void;
	function SetTrimming(t:Ptr, sign:Ptr):Void;
	function SetLineSpacing(method:Int, spacing:Float32, baseline:Float32):Void;
	@:hxmc.com.direct function GetTextAlignment():Int;
	@:hxmc.com.direct function GetParagraphAlignment():Int;
	@:hxmc.com.direct function GetWordWrapping():Int;
	@:hxmc.com.direct function GetReadingDirection():Int;
	@:hxmc.com.direct function GetFlowDirection():Int;
	@:hxmc.com.direct function GetIncrementalTabStop():Float32;
	function GetTrimming(t:Ptr, sign:Ptr):Void;
	function GetLineSpacing(method:Ptr, spacing:Ptr, baseline:Ptr):Void;
	function GetFontCollection():IUnknown;
	@:hxmc.com.direct function GetFontFamilyNameLength():Int;
	function GetFontFamilyName(buf:Ptr, size:Int):Void;
	@:hxmc.com.direct function GetFontWeight():Int;
	@:hxmc.com.direct function GetFontStyle():Int;
	@:hxmc.com.direct function GetFontStretch():Int;
	@:hxmc.com.direct function GetFontSize():Float32;
	@:hxmc.com.direct function GetLocaleNameLength():Int;
	function GetLocaleName(buf:Ptr, size:Int):Void;
}

// (C++'s overloads of the format's getters take other names here: a slot is
// its place, whatever its name)
@:hxmc.com("{53737037-6d14-410b-9bfe-0b182bb70961}")
extern interface IDWriteTextLayout extends IDWriteTextFormat {
	function SetMaxWidth(w:Float32):Void;
	function SetMaxHeight(h:Float32):Void;
	function SetFontCollection(c:IUnknown, start:Int, length:Int):Void;
	function SetFontFamilyName(name:String, start:Int, length:Int):Void;
	function SetFontWeight(w:Int, start:Int, length:Int):Void;
	function SetFontStyle(s:Int, start:Int, length:Int):Void;
	function SetFontStretch(s:Int, start:Int, length:Int):Void;
	function SetFontSize(size:Float32, start:Int, length:Int):Void;
	function SetUnderline(on:Int, start:Int, length:Int):Void;
	function SetStrikethrough(on:Int, start:Int, length:Int):Void;
	function SetDrawingEffect(effect:Ptr, start:Int, length:Int):Void;
	function SetInlineObject(o:Ptr, start:Int, length:Int):Void;
	function SetTypography(t:Ptr, start:Int, length:Int):Void;
	function SetLocaleName(name:String, start:Int, length:Int):Void;
	@:hxmc.com.direct function GetMaxWidth():Float32;
	@:hxmc.com.direct function GetMaxHeight():Float32;
	function GetFontCollectionAt(pos:Int, c:Ptr, range:Ptr):Void;
	function GetFontFamilyNameLengthAt(pos:Int, n:Ptr, range:Ptr):Void;
	function GetFontFamilyNameAt(pos:Int, buf:Ptr, size:Int, range:Ptr):Void;
	function GetFontWeightAt(pos:Int, w:Ptr, range:Ptr):Void;
	function GetFontStyleAt(pos:Int, s:Ptr, range:Ptr):Void;
	function GetFontStretchAt(pos:Int, s:Ptr, range:Ptr):Void;
	function GetFontSizeAt(pos:Int, size:Ptr, range:Ptr):Void;
	function GetUnderline(pos:Int, on:Ptr, range:Ptr):Void;
	function GetStrikethrough(pos:Int, on:Ptr, range:Ptr):Void;
	function GetDrawingEffect(pos:Int, e:Ptr, range:Ptr):Void;
	function GetInlineObject(pos:Int, o:Ptr, range:Ptr):Void;
	function GetTypography(pos:Int, t:Ptr, range:Ptr):Void;
	function GetLocaleNameLengthAt(pos:Int, n:Ptr, range:Ptr):Void;
	function GetLocaleNameAt(pos:Int, buf:Ptr, size:Int, range:Ptr):Void;
	function Draw(context:Ptr, renderer:Ptr, x:Float32, y:Float32):Void;
	function GetLineMetrics(metrics:Ptr, max:Int, count:Ptr):Void;
	function GetMetrics():TextMetrics;
}

@:hxmc.com("{b859ee5a-d838-4b5b-a2e8-1adc7d93db48}")
extern interface IDWriteFactory extends IUnknown {
	function GetSystemFontCollection(out:Ptr, check:Int):Void;
	function CreateCustomFontCollection(loader:Ptr, key:Ptr, size:Int, out:Ptr):Void;
	function RegisterFontCollectionLoader(loader:Ptr):Void;
	function UnregisterFontCollectionLoader(loader:Ptr):Void;
	function CreateFontFileReference(path:String, time:Ptr, out:Ptr):Void;
	function CreateCustomFontFileReference(key:Ptr, size:Int, loader:Ptr, out:Ptr):Void;
	function CreateFontFace(type:Int, n:Int, files:Ptr, index:Int, flags:Int, out:Ptr):Void;
	function CreateRenderingParams(out:Ptr):Void;
	function CreateMonitorRenderingParams(monitor:Ptr, out:Ptr):Void;
	function CreateCustomRenderingParams(gamma:Float32, contrast:Float32, clear:Float32, geometry:Int, mode:Int, out:Ptr):Void;
	function RegisterFontFileLoader(loader:Ptr):Void;
	function UnregisterFontFileLoader(loader:Ptr):Void;
	function CreateTextFormat(family:String, collection:Null<IUnknown>, weight:Int, style:Int, stretch:Int, size:Float32, locale:String):IDWriteTextFormat;
	function CreateTypography(out:Ptr):Void;
	function GetGdiInterop(out:Ptr):Void;
	function CreateTextLayout(text:String, length:Int, format:IDWriteTextFormat, maxWidth:Float32, maxHeight:Float32):IDWriteTextLayout;
}

@:hxmc.c @:hxmc.lib("dwrite") extern class DWrite {
	static function DWriteCreateFactory(type:Int, riid:Ptr, out:Ptr):Int;
}

// a Haxe object as the dialog's events' sink
class Events implements IFileDialogEvents {
	public var seen:Array<String> = [];

	public function new() {}

	public function OnFileOk(dialog:IFileDialog)
		seen.push("ok");

	public function OnFolderChanging(dialog:IFileDialog, folder:IShellItem)
		seen.push("folder changing");

	public function OnFolderChange(dialog:IFileDialog)
		seen.push("folder change");

	public function OnSelectionChange(dialog:IFileDialog)
		seen.push("selection");

	public function OnShareViolation(dialog:IFileDialog, item:IShellItem, response:Ptr<Int32>)
		throw new ComException(ComException.E_NOTIMPL);

	public function OnTypeChange(dialog:IFileDialog)
		seen.push("type");

	public function OnOverwrite(dialog:IFileDialog, item:IShellItem, response:Ptr<Int32>)
		throw new ComException(ComException.E_NOTIMPL);
}

class ComDemos {
	static inline var CLSID_FileOpenDialog = "{DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7}";
	static inline var FOS_FORCEFILESYSTEM = 0x40;
	static inline var FOS_FILEMUSTEXIST = 0x1000;
	static inline var SIGDN_FILESYSPATH = 0x80058000;

	static function dialog() {
		var d = Com.create(CLSID_FileOpenDialog, IFileOpenDialog);
		d.SetOptions(d.GetOptions() | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
		var o = d.GetOptions();
		trace("options", o & FOS_FORCEFILESYSTEM != 0, o & FOS_FILEMUSTEXIST != 0);
		d.SetTitle("Pick a file \u2014 hxmc");
		d.SetFileName("notes \u00e9t\u00e9.txt");
		trace("file name", d.GetFileName());
		// (COMDLG_FILTERSPEC: two LPCWSTRs each; a BSTR is one)
		var specs = Mem.stack(32);
		var names = [Com.bstr("Text"), Com.bstr("*.txt"), Com.bstr("Any"), Com.bstr("*.*")];
		for (i in 0...4)
			Mem.setPtr(specs, 8 * i, names[i]);
		d.SetFileTypes(2, specs);
		d.SetFileTypeIndex(2);
		trace("file type", d.GetFileTypeIndex());
		for (n in names)
			Com.freeBstr(n);
		// a shell item of C's (an [out] interface pointer, adopted), as the folder
		var out = Mem.stack(8);
		var root = Com.bstr("C:\\");
		var hr = Shell32.SHCreateItemFromParsingName(root, Ptr.nil(), Com.iidOf(IShellItem), out);
		Com.freeBstr(root);
		if (hr < 0) throw new ComException(hr);
		var item = Com.adopt(Mem.getPtr(out, 0), IShellItem);
		d.SetFolder(item);
		trace("folder", d.GetFolder().GetDisplayName(SIGDN_FILESYSPATH));
		// its interfaces: IFileDialog is IFileOpenDialog's base (IModalWindow too:
		// its Show is d's slot 3)
		var fd = Com.query(d, IFileDialog);
		trace("interfaces", fd != null, Com.same(d, fd), Com.query(d, IShellItem) == null, Std.isOfType(d, IShellItem));
		// a Haxe object as the dialog's events' sink: the dialog holds it while advised
		var events = new Events();
		var before = Com.refCount(events);
		var cookie = d.Advise(events);
		var advised = Com.refCount(events);
		d.Unadvise(cookie);
		trace("advise", before, advised > before, Com.refCount(events) == before, events.seen);
	}

	static function dwrite() {
		var out = Mem.stack(8);
		var hr = DWrite.DWriteCreateFactory(0, Com.iidOf(IDWriteFactory), out);
		if (hr < 0) throw new ComException(hr);
		var factory = Com.adopt(Mem.getPtr(out, 0), IDWriteFactory);
		var format = factory.CreateTextFormat("Tahoma", null, 400, 0, 5, 16, "en-us");
		trace("format", format.GetFontSize(), format.GetFontWeight(), format.GetFontFamilyNameLength(), format.GetLocaleNameLength());
		format.SetWordWrapping(0);
		var text = "Hello, DirectWrite from hxmc: a text long enough to wrap onto lines of its own.";
		var layout = factory.CreateTextLayout(text, text.length, format, 120, 400);
		var m = layout.GetMetrics();
		var width:Float = m.width, height:Float = m.height;
		trace("layout", width > 0 && width <= 120, m.lineCount > 1, height > 0, layout.GetMaxWidth());
		layout.SetMaxWidth(10000);
		var one = layout.GetMetrics();
		trace("one line", one.lineCount, (one.width : Float) > width);
		trace("a layout is a format", Com.query(layout, IDWriteTextFormat) != null, layout.GetFontSize());
	}

	static function main() {
		Com.init(SingleThreaded);
		dialog();
		dwrite();
		hxmc.NativeGc.collect(true);
		Com.runDeferred();
		Com.uninit();
		trace("done");
	}
}
