package lix.cli;

import haxeshim.sys.*;
import haxe.DynamicAccess;
import lix.client.Archives;
import lix.client.sources.*;
import lix.client.*;

using haxe.io.Path;

class Cli {

  // port: CompileTime.parseJsonFile("package.json").version of the lix release this is ported from
  static public inline var VERSION = '17.0.3';

  static public function main(?args:Array<String>)
    Command.attempt(() -> {
      HaxeCmd.ensureScope();
      dispatch(args ?? Sys.args());
    });

  static function dispatch(args:Array<String>) {
    var version = VERSION;
    var silent = args.remove('--silent'),
        force = args.remove('--force'),
        global = args.remove('--global') || args.remove('-g'),
        flat = args.remove('--flat');

    var scope = Scope.seek({ cwd: if (global) Scope.DEFAULT_ROOT else null });

    args = Command.expand(args, [
      "+tink install github:haxetink/tink_${0}",
      "+coco install github:MVCoconut/coconut.${0}",
      "+lib install haxelib:${0}",
    ]);

    function grab(name:String)
      return switch args.indexOf(name) {
        case -1: null;
        case v: args.splice(v, 2)[1];
      }

    var gitlab = new GitLab(grab('--gl-private-token')),
        github = new GitHub(switch grab('--gh-credentials') {
          case null: null;
          case _.split(':') => [user, tk]: '$user:$tk';
          case v: Exec.die(422, '`--gh-credentials $v` should be `--gh-credentials <user>:<token>`');
        });

    var haxelibUrl = grab('--haxelib-url');
    var web = new Web([gitlab.intercept, github.intercept]);
    var sources:Array<ArchiveSource> = [web, new Haxelib(haxelibUrl), github, gitlab, new Git(scope)];
    var resolvers:Map<String, ArchiveSource> = [for (s in sources) for (scheme in s.schemes()) scheme => s];

    function resolve(url:Url):ArchiveJob
      return switch resolvers[url.scheme] {
        case null:
          throw new Error('Unknown scheme in url $url');
        case v:
          v.processUrl(url);
      }

    var logger = Logger.get(silent);

    var hx = new lix.client.haxe.Switcher(scope, logger);
    var libs = new Libraries(
      scope,
      resolve,
      logger,
      force
    );

    Command.dispatch(args, 'lix - Libraries for Haxe (v$version)', [
      new Command('install', '<url> [as <lib[#ver]>]', 'install lib from specified url',
        function (args)
          if (scope.isGlobal && !global)
            throw new Error('Current scope is global. Please use --global if you intend to install globally, or create a local scope with `lix scope create`.');
          else
            switch args {
              case ['haxe', version]:
                hx.install(version, { force: force });
              case [url, 'as', alias]:
                libs.installUrl(Url.parse(url), LibVersion.parse(alias), { flat: flat });
              case [library, _] | [library] if (Url.parse(library).scheme == null):
                throw new Error('Did you mean `lix install haxelib:$library`?');
              case [url]:
                libs.installUrl(Url.parse(url), { flat: flat });
              case []: throw new Error('Missing url');
              case v: throw new Error('too many arguments');
            }
      ),
      new Command('install haxe', '<version>|<alias>', 'install specified haxe version', null),//this is never matched and is here purely for usage display
      new Command('use', 'haxe <version>|<alias>', 'use specified haxe version', function (args) switch args {
        case ['haxe', version]: hx.switchTo(hx.resolveInstalled(version));
        default: throw new Error('invalid arguments');
      }),
      new Command('dev', '<lib> <path>', 'use dev version of library', args -> switch args {
        case [lib, path]: libs.dev(lib, path);
        default: throw new Error('invalid arguments');
      }),
      new Command('download haxe', '<version>|<alias>', 'download specified haxe version', null),//this is never matched and is here purely for usage display
      new Command('scope', '[create|delete]', 'creates or deletes the current scope or\ninspects it if no argument is supplied',
        function (args) switch args {
          case ['create']:
            Scope.create(scope.cwd, {
              version: scope.config.version,
              resolveLibs: if (scope.isGlobal) Scoped else scope.config.resolveLibs,
            });
            logger.success('created scope in ${scope.cwd}');
          case ['delete']:
            if (scope.isGlobal)
              throw new Error('Cannot delete global scope');
            else {
              scope.delete();
              logger.success('deleted scope in ${scope.scopeDir}');
            }
          case []:
            logger.info(
              (if (scope.isGlobal) '[global]' else '[local]') + ' ${scope.scopeDir}'
            );
          case v:
            throw new Error('Invalid arguments');
        }
      ),
      new Command('haxe-versions', '', 'lists currently downloaded versions',
        function (args) switch args {
          case []:
            var o = hx.officialInstalled(IncludePrereleases);
            var n = hx.nightliesInstalled();
            function highlight(s:String)
              return
                if (s == scope.config.version)
                  ' -> $s';
                else
                  '    $s';

            println('');
            println('Official releases:');
            println('');

            for (v in o)
              println(highlight(v));

            if (n.iterator().hasNext()) {
              println('');
              println('Nightly builds:');
              println('');

              for (v in n)
                println(highlight(v.hash) + v.published.format('  (%Y-%m-%d %H:%M)'));
            }

            var h = hx.hxmcInstalled();
            if (h.length > 0) {
              println('');
              println('hxmc builds:');
              println('');

              for (v in h)
                println(highlight(v));
            }

            println('');
          default:
            throw new Error('command `list` does expect arguments');
        }
      ),
      new Command('download', '[<url[#lib[#ver]]>]', 'download lib from url if specified,\notherwise download missing libs',
        function (args) switch args {
          case ['haxe', version]:
            hx.resolveAndDownload(version, { force: force });
          case [url, 'as', legacy]:
            var target = legacy.replace('#', '/');
            var absTarget = scope.libCache + '/$target';
            function shorten(s:String)
              return
                if (s.length > 40) s.substr(0, 37)+ '...';
                else s;

            if (absTarget.exists())
              throw new Error('`download <url> as <ver>` is no longer supported');
            else {
              logger.warning('Warning: Processing obsolete `download ${args.map(shorten).join(" ")}`.\n        Please reinstall library in a timely manner!\n\n');
              var a = libs.downloadUrl(Url.parse(url), { into: target });
              Fs.ensureDir(absTarget);
              a.absRoot.rename(absTarget);
            }
          case [url, 'into', dir]:

            libs.downloadUrl(Url.parse(url), { into: dir });

          case [url]:

            libs.downloadUrl(Url.parse(url));

          case []:

            lix.client.haxe.Switcher.ensureNeko(scope.haxeInstallation.neko, logger);
            hx.download(hx.resolveOnline(scope.config.version), { force: false });
            new HaxeCli(scope).installLibs(silent);

          case v: throw new Error('too many arguments');
        }
      ),
      new Command('run', 'lib ...args', 'run a library', function (args) switch args {
        case []: throw new Error('no library specified');
        case args:
          switch scope.getLibCommand(args)() {
            case Success(_):
            case Failure(e): throw e;
          }
      }),
      new Command(['--version', '-v'], '', 'print version', function (args)
        if (args.length > 0) throw new Error('too many arguments')
        else {
          Sys.println(version);
        }
      ),
      new Command('shims', '[<dir>]', 'creates haxe, haxelib and neko commands next to\nthis binary (or in <dir>) that run as lix does', args -> switch args {
        case []: shims(null, force, logger);
        case [dir]: shims(dir, force, logger);
        default: throw new Error('too many arguments');
      }),
      new Command('run-haxelib', 'path ...args', 'invoke a haxelib at a given path following haxelib\'s conventions', function (args)
        switch args {
          case []: throw new Error('no path supplied');
          default:
            var sliced = args.slice(1);
            new HaxelibCli(scope).run(sliced, sliced); // TODO: should we handle flags (e.g. --cwd/--global) as in HaxelibShimCli?
        }
      ),
    ], [],
      args -> switch args[0] {
        case null: null;
        case '-lib' | '--library' | '-L' | '--run' | (_.endsWith('.hxml') => true):
          () -> @:privateAccess new HaxeCli(scope).dispatch(args);
        case lib if (scope.libHxml(lib).exists()):
          () -> new HaxelibCli(scope).run(args, args); // TODO: should we handle flags (e.g. --cwd/--global) as in HaxelibShimCli?
        case cls if (isClassName(cls)):
          () -> runScript(scope, cls, args);
        default: null;
      }
    );
  }

  static function runScript(scope:Scope, cls:String, args:Array<String>) {
    function absolute(path:String)
      return Path.join([scope.scopeDir, path]);

    var info:{ classPath:String, name:String, dependencies:DynamicAccess<String> } =
      try haxe.Json.parse(Fs.get(absolute('haxelib.json')))
      catch (e:Dynamic) {
        classPath: '',
        name: scope.scopeDir.removeTrailingSlashes().withoutDirectory(),
        dependencies: new DynamicAccess<String>()
      };

    var file = cls.replace('.', '/') + '.hx';

    var candidates = [
      { file: file, args: ['-cp', absolute('')] },
      { file: 'scripts/$file', args: ['-cp', absolute('scripts')] }
    ];

    switch info.classPath {
      case null | '':
      case cp:
        candidates.push({
          file: '$cp/$file',
          args:
            if (scope.libHxml(info.name).exists()) ['-lib', info.name]
            else {
              var ret = [];
              switch info.dependencies {
                case null: [];
                case deps:
                  for (k => v in deps) {
                    ret.push('-lib');
                    ret.push(k);
                  }
              }
              ret.concat(['-cp', absolute(cp)]);
            }
        });
      }

    for (c in candidates)
      switch Path.join([scope.scopeDir, c.file]) {
        case _.exists() => false:
        case found:
          var content = Fs.get(found);
          var buildArgs = [];
          {
            var lines = content.split('\n'),
                pos = 0;
            if (lines[0].startsWith('#!'))
              pos++;
            while (true)
              switch lines[pos++].trim() {
                case '':
                case content:
                  if (content.startsWith('//!')) {
                    for (v in content.substr(3).split(' '))
                      switch v.trim() {
                        case '':
                        case v: buildArgs.push(v);
                      }
                  }
                  else break;
              }
          }

          buildArgs = buildArgs.concat(c.args);
          var runArgs = args.slice(1);

          switch scope.getBuilds(buildArgs) {
            case Failure({ errors: errors }) | Success([Failure({ errors: errors })]):
              var e = errors[0];
              throw new Error(e.code ?? 500, e.pos.toString() + ': ' + e.message);
            case Success([Success(build)]):
              switch build.checkClassPaths() {
                case Failure({ errors: errors }):
                  var e = errors[0];
                  throw new Error(e.code ?? 500, e.pos.toString() + ': ' + e.message);
                default:
              }
              var cwd = build.cwd;
              var args = [for (a in build.args) a.val];
              var nodeFile = null;

              for (i in 0...args.length - 1)
                switch args[i] {
                  case '-D' | '--define':
                    switch args[i + 1] {
                      case 'hxnodejs', _.startsWith('hxnodejs=') => true:
                        nodeFile = switch args.indexOf('-js') {
                          case -1:
                            var ret = found.withoutExtension().withExtension('js');
                            args = args.concat(['-js', ret]);
                            ret;
                          case v:
                            args[v + 1];//could be null ... perhaps should be forbidden altogether
                        }
                        break;
                      default:
                    }
                  default:
                }

              args = args.concat(switch nodeFile {
                case null: ['--run', cls].concat(runArgs);
                default: ['-main', cls];
              });

              switch Exec.sync(scope.haxeInstallation.compiler, cwd, args, scope.haxeInstallation.env) {
                case Success(0):
                  switch nodeFile {
                    case null:
                    default:
                      var script = Fs.get(nodeFile);
                      Fs.save(nodeFile, [
                        'try { require("fs").unlinkSync(__filename); } catch (e) {}',
                        script,
                      ].join('\n'));
                      switch Exec.sync('node', cwd, [nodeFile].concat(runArgs)) {
                        case Success(0):
                        case Success(v): throw new Error(v, 'node exited with code $v');
                        case Failure(e): throw e;
                      }
                  }
                case Success(v): throw new Error(v, 'haxe exited with code $v');
                case Failure(e): throw e;
              }
            case Success(_):
              throw new Error('multiple builds defined');
          }

          return;
      }

    throw new Error(NotFound, 'Class not found: $cls');
  }

  // port: not in the npm package, whose four commands npm installs. One binary
  // is all four, by the name it runs as (Main.hx): links to it make the others,
  // symbolic links where they are cheap, hard links (or copies) on Windows,
  // where symbolic links need administrator rights.
  static function shims(dir:Null<String>, force:Bool, logger:Logger) {
    var self = Sys.programPath();
    if (dir == null)
      dir = self.directory();
    var ext = if (Os.IS_WINDOWS) '.exe' else '';
    // `lix` too, when this binary has another name (lix-linux-x86_64 as
    // downloaded): the libraries' install commands call lix by that name
    var cmds = ['haxe', 'haxelib', 'neko'];
    if (self.withoutDirectory().withoutExtension().toLowerCase() != 'lix')
      cmds.unshift('lix');
    var paths = [for (cmd in cmds) Path.join([dir, cmd + ext])];
    paths = [for (p in paths) if (Path.normalize(p) != Path.normalize(self)) p];
    // every name is checked before any is replaced
    for (path in paths)
      if (uv.Uv.Fs.isSymlink(path) || path.exists()) {
        if (path.isDirectory() && !uv.Uv.Fs.isSymlink(path))
          throw new Error('$path is a directory');
        if (!force)
          throw new Error('$path already exists. Use --force to replace it.');
      }
    for (path in paths) {
      if (uv.Uv.Fs.isSymlink(path) || path.exists())
        path.deleteFile();
      if (Os.IS_WINDOWS)
        try uv.Uv.Fs.link(self, path)
        catch (e:uv.Uv.UvError) sys.io.File.copy(self, path);
      else
        uv.Uv.Fs.symlink(if (dir.normalize() == self.directory().normalize()) self.withoutDirectory() else self, path);
      logger.success('created $path');
    }
  }

  static function isClassName(s:String) {
    var char = s.split('.').pop().charCodeAt(0);
    return char >= 'A'.code && char <= 'Z'.code;
  }

}
