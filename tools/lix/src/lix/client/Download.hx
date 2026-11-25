package lix.client;

import shim.Archive;
import shim.Http;

typedef Directory = String;

// port: node's http/https, yauzl and tar streams become a buffered download
// (shim.Http) and extraction from memory (shim.Archive), synchronously
class Download {

  static public function text(url:String):String
    return bytes(url).toString();

  static public function bytes(url:String):Bytes
    return download(url, null).body;

  static public function archive(url:String, peel:Int, into:String, ?logger:Logger):Directory {
    var res = download(url, logger);
    return
      if (res.headers['content-type'] == 'application/zip' || url.endsWith('.zip') || res.url.endsWith('.zip'))
        extract(url, Archive.unzip(res.body), into, peel, logger);
      else
        extract(url, untar(res.body), into, peel, logger);
  }

  static function untar(b:Bytes)
    return Archive.untar(if (Archive.isGzip(b)) Archive.gunzip(b) else b);

  static public function tar(url:String, peel:Int, into:String, logger:Logger):Directory
    return extract(url, untar(download(url, logger).body), into, peel, logger);

  // a tarball already downloaded (src: where from, for the log)
  static public function untarBytes(src:String, bytes:Bytes, peel:Int, into:String, ?logger:Logger):Directory
    return extract(src, untar(bytes), into, peel, logger);

  static public function zip(url:String, peel:Int, into:String, logger:Logger):Directory
    return extract(url, Archive.unzip(download(url, logger).body), into, peel, logger);

  static function stripLeadingSlashes(path:String)
    return
      if (path.charAt(0) == '/') stripLeadingSlashes(path.substr(1));
      else path;

  static function extract(src:String, entries:Array<ArchiveEntry>, into:String, peel:Int, logger:Null<Logger>):Directory {
    var total = 0,
        saved = 0;
    for (e in entries)
      switch e.kind {
        case File(data): total += data.length;
        default:
      }

    var progress = new Progress(logger);
    var symlinks = [],
        hardlinks = [];

    for (entry in entries)
      switch Fs.peel(stripLeadingSlashes(entry.path), peel) {
        case null:
        case f:
          // port: entries escaping the target directory are skipped
          if (f.split('/').contains('..'))
            continue;
          var path = '$into/$f';
          switch entry.kind {
            case Directory:
              Fs.ensureDir(path.addTrailingSlash());
            case _ if (path.endsWith('/')):
            case File(data):
              Fs.ensureDir(path);
              path.saveBytes(data);
              if (entry.mode & 0x1FF != 0 && !Os.IS_WINDOWS)
                uv.Uv.Fs.chmod(path, entry.mode & 0x1FF);
              saved += data.length;
              progress.saved(saved, total);
            case Symlink(target):
              Fs.ensureDir(path);
              symlinks.push({ from: target, to: path });
            case HardLink(target):
              hardlinks.push({ from: '$into/${Fs.peel(stripLeadingSlashes(target), peel)}', to: path });
          }
      }

    for (link in hardlinks)
      if (link.from.exists()) {
        Fs.ensureDir(link.to);
        sys.io.File.copy(link.from, link.to);
      }

    for (link in symlinks) {
      if (link.to.exists() || uv.Uv.Fs.isSymlink(link.to))
        Fs.delete(link.to);
      try uv.Uv.Fs.symlink(link.from, link.to)
      catch (e:uv.Uv.UvError) throw new Error(e.message);
    }

    if (logger != null)
      logger.success('-> Done!');
    return into;
  }

  static function download(url:String, logger:Null<Logger>):Response {
    var progress = new Progress(logger);
    return
      try Http.request(url, null, progress.downloaded)
      catch (e:Error)
        if (e.code >= 400) throw e
        else throw Error.withData(e.code, 'Failed to download $url because ${e.message}', e);
  }

  static public var USER_AGENT(get, set):String;
    static function get_USER_AGENT() return Http.USER_AGENT;
    static function set_USER_AGENT(v) return Http.USER_AGENT = v;
}

// the progress line of lix.client.Download.withLogger
private class Progress {
  final logger:Null<Logger>;
  var last:String = null;
  var lastUpdate = .0;

  public function new(logger)
    this.logger = logger;

  static function pct(f:Float) {
    f = Math.min(1, Math.max(0, f));
    return (switch Std.string(Math.round(1000 * f) / 10) {
      case whole = _.indexOf('.') => -1: '$whole.0';
      case v: v;
    }).lpad(' ', 5) + '%';
  }

  function show(s:String) {
    if (logger == null || s == last) return;
    var now = Date.now().getTime();
    if (now <= lastUpdate + 137) return;
    lastUpdate = now;
    last = s;
    logger.progress(s);
  }

  public function downloaded(loaded:Int, size:Int)
    if (size > 0 && loaded < size)
      show('   Downloaded: ${pct(loaded / size)}');

  public function saved(saved:Int, total:Int)
    if (total > 0 && saved < total)
      show('   Saved: ${pct(saved / total)}');
}
