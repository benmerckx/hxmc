package lix.client.haxe;

import haxe.DynamicAccess;

/**
 * hxmc's builds from npm's registry, read directly (no npm client, no node): `@hxmc/cli` and this machine's
 * `@hxmc/<platform>-<arch>` (one of its optional dependencies, as npm picks it), unpacked as npm would install
 * them under `<root>/hxmc/<version>/node_modules` and set up as the package's postinstall does
 * (packages/cli/hxmc/bootstrap/launcher.mjs: setupDist, install), and `<root>/versions/hxmc-<version>` a link to
 * the package's `dist/`, the installation it ships for lix.
 *
 * As a version: `hxmc-<npm version>` (pinned, what `.haxerc` holds), `hxmc-<dist-tag>` (`latest`, `next`) or
 * `hxmc-<commit>` (a nightly's, the last part of its version), and `hxmc` alone for `hxmc-latest`.
 */
class Hxmc {

  static public inline var PREFIX = 'hxmc-';
  static inline var CLI = '@hxmc/cli';
  static inline var REGISTRY = 'https://registry.npmjs.org/';

  static public function isHxmc(version:String)
    return version == 'hxmc' || version.startsWith(PREFIX);

  // the spec after `hxmc-` (`latest` for `hxmc`)
  static public function spec(version:String)
    return if (version == 'hxmc') 'latest' else version.substr(PREFIX.length);

  // npm's documents of the packages (their versions' metadata, `dist-tags`), once per run
  static final packuments = new Map<String, Dynamic>();

  static function packument(name:String):Dynamic
    return packuments[name] ??= Download.text(REGISTRY + name.replace('/', '%2F')).parse();

  static function meta(name:String, version:String):Dynamic {
    final versions:DynamicAccess<Dynamic> = packument(name).versions;
    return switch versions[version] {
      case null: throw new Error(NotFound, '$name has no version $version');
      case v: v;
    }
  }

  // the npm version a spec names: a dist-tag, an exact version, or a commit that ends exactly one version
  static public function resolve(spec:String):String {
    final p = packument(CLI);
    final versions:DynamicAccess<Dynamic> = p.versions,
          tags:DynamicAccess<String> = Reflect.field(p, 'dist-tags');
    if (tags != null && tags.exists(spec)) return tags[spec];
    if (versions.exists(spec)) return spec;
    return switch [for (v in versions.keys()) if (v.endsWith('.$spec')) v] {
      case [v]: v;
      case []: throw new Error(NotFound, 'No hxmc build $spec on npm (neither a version of $CLI, a dist-tag, nor a commit)');
      case several: throw new Error('hxmc build $spec is ambiguous: ${several.join(', ')}');
    }
  }

  // npm's name of this machine's platform package (its `os` and `cpu`, as npm matches them)
  static function platformPackage():String
    return '@hxmc/' + switch Os.platform {
      case Linux64: 'linux-x64';
      case LinuxArm64: 'linux-arm64';
      case Mac64: 'darwin-x64';
      case MacArm: 'darwin-arm64';
      case Win64: 'win32-x64';
      case v: throw new Error(NotFound, 'hxmc has no build for this machine ($v)');
    }

  // a version of a package, unpacked into dir (afresh)
  static function unpack(name:String, version:String, dir:String, logger:Logger) {
    final dist = meta(name, version).dist;
    logger.info('  $name@$version');
    final bytes = Download.bytes(dist.tarball);
    Fs.delete(dir);
    // (npm's tarballs hold the package in `package/`)
    Download.untarBytes(dist.tarball, bytes, 1, dir);
  }

  /**
   * Installs version (an exact npm version) into `<root>/hxmc/<version>` and links `target` (the version's
   * directory in `<root>/versions`) to its installation.
   */
  static public function install(version:String, root:String, target:String, logger:Logger) {
    final base = '$root/hxmc/$version/node_modules',
          platform = platformPackage();
    final optional:DynamicAccess<String> = meta(CLI, version).optionalDependencies;
    if (optional == null || !optional.exists(platform))
      throw new Error(NotFound, 'hxmc $version has no build for this machine ($platform)');

    final cli = '$base/$CLI',
          exe = 'haxe${Os.EXECUTABLE_EXTENSION}';
    unpack(CLI, version, cli, logger);
    unpack(platform, version, '$base/$platform', logger);

    final native = '$base/$platform/$exe';
    switch Exec.eval(native, root, ['--version']) {
      case Success({ status: 0 }):
      case Success({ status: s, stderr: e }): throw new Error('hxmc $version does not run here (exit code $s): $e');
      case Failure(e): throw e;
    }

    // dist/: std (upstream's), platform.txt, and the native compiler in place of the launcher (on Unix also the
    // package's hxmc/bootstrap/haxe, as its postinstall does)
    final dist = '$cli/dist';
    link('../haxe/upstream/std', '$dist/std');
    '$dist/platform.txt'.saveContent(Os.platform);
    for (copy in if (Os.IS_WINDOWS) ['$dist/$exe'] else ['$dist/$exe', '$cli/hxmc/bootstrap/$exe']) {
      Fs.delete(copy);
      sys.io.File.copy(native, copy);
      if (!Os.IS_WINDOWS) uv.Uv.Fs.chmod(copy, 0x1ED);
    }

    link(dist.fullPath(), target);
  }

  // a link to a directory (relative on Unix, resolved from where the link is; a junction on Windows, which needs
  // an absolute target)
  static function link(to:String, at:String) {
    Fs.delete(at);
    try
      if (Os.IS_WINDOWS) uv.Uv.Fs.symlink(Path.join([at.directory(), to]).fullPath(), at, uv.Uv.Fs.SYMLINK_JUNCTION)
      else uv.Uv.Fs.symlink(to, at, uv.Uv.Fs.SYMLINK_DIR)
    catch (e:uv.Uv.UvError) throw new Error('Failed to link $at to $to: ${e.message}');
  }
}
