# @hxmc/3d

A scene layer for 3D games on `@hxmc/gfx`, in pure Haxe (Haxe package
`hxmc.scene`; the plan and its order: docs/plans/3d.md). It is ordinary gfx
code: use the parts you want, replace the rest.

## Math

gfx's shader types (`Vec2`, `Vec3`, `Vec4`, `Mat4` of `hxmc.gfx.shader`)
are the CPU's types too, so what the CPU computes is what a shader reads.
3d adds, as immutable values like them:

- `Quat`: a unit quaternion (`axisAngle`, `fromEuler`, `fromMat4`, `*`,
  `rotate`, `toMat4`, `slerp`, `conjugate`);
- `Aabb`: an axis-aligned box (`union`, `transform`, `contains`,
  `intersects`, `ray`);
- `MathTools`, a static extension of `Mat4` (`using
  hxmc.scene.math.MathTools`): `inverse`, `transpose`, `determinant`,
  `compose(t, r, s)`, `decompose`, `lookAt`, `lookRotation`,
  `transformPoint`, `transformDir`, `normalMatrix`.

## World

A `World` is a scene graph of `Node`s: handles (an `Int`: the world, a
generation, a slot) over flat arrays of transforms, so nodes cost no
object each and a disposed node's handle is stale (`valid` false).

```haxe
var world = new World();
var arm = world.node("arm");                 // under world.root
arm.position = new Vec3(2, 0, 0);            // Vec3 and Quat: immutable values
arm.rotation = Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 2);
var hand = world.node("hand", arm);
var eye = world.node("eye");
var camera = Camera.attach(eye, Camera.perspective(Math.PI / 3, 0.1, 100));
eye.position = new Vec3(4, 3, 6);
eye.lookAt(new Vec3(0, 1, 0));
var mvp = camera.viewProjection(width / height) * hand.worldMatrix();
```

A node's `worldMatrix()` is cached until a transform above it changes.
What nodes carry is in typed stores (`world.store(kind)`, a `StoreKind`
per kind: `Camera.KIND`, `MeshRenderer.KIND`, `Light.KIND`), made when
first used. `FixedStep` runs a simulation at a fixed rate from the app
loop's frames and gives the fraction between the last two steps; `Stages` runs a frame's work in
ordered stages (`Input`, `FixedUpdate`, `Update`, `LateUpdate`, `PreRender`).

## glTF

`Gltf.parse(bytes, ?resolve)` reads glTF 2.0, .gltf (buffers as `data:`
URIs or files `resolve` returns) and .glb, into a `GltfDoc`: typed and
checked data (indices in range, views inside buffers, accessors inside
views). `doc.floats(accessor)` and `doc.indices(accessor)` read accessors of
any component type, normalized or strided. `GltfNodes.build(doc, world, ?parent, ?scene, ?mesh)` makes the node
hierarchy (TRS or matrices, cameras); `GltfScene` makes the GPU meshes and
materials once and `instantiate(world)` copies the hierarchy into a world.
`Asset.embed(path)` builds a file into the program.

## Models

```haxe
var hero = Model.of("models/hero.glb");      // checked and typed when compiling
var root = hero.instantiate(world, device);  // GPU meshes made once, shared
var hand = root.find(hero.nodes.LeftHand);   // hero.nodes.LeftHnad: a compile error
```

`Model.of` reads the file's names when compiling (nodes, meshes,
materials, animations: `model.nodes`, ...). A file up to 64 KB is built
into the program (`-D hxmc.scene.embed=<bytes>`); a larger one is copied
beside it (`assets/`, listed in `<output>.assets.json`), read from beside
the executable natively and fetched before main in the browser
(`browser.mjs`'s `assets` option: `run(wasm, {assets: 'app.wasm.assets.json'})`);
the repository tool's `hxmc <output> ...` form needs `-D hxmc.scene.out=<output>`.
For now self-contained files only for now (one embedded
buffer, images inside it). Textures need a decoder, named by
the program so that none is linked otherwise:

```haxe
Images.decode = (mime, bytes) -> mime == "image/jpeg" ? hxmc.ui.JpegDecoder.decode(bytes) : hxmc.ui.PngDecoder.decode(bytes);
```

## The asset step

```sh
bin/hxmc/hxmc -cp packages/os/src -cp packages/gfx/src -cp packages/3d/src \
  --run hxmc.scene.gltf.Pack level.glb level.hxm3d
```

```haxe
PackedModel.read(Asset.embed("level.hxm3d"), device).instantiate(world);
```

A packed model needs no glTF reader or JSON at run time (73 KB less
natively, `make 3d-sizes`): meshes (vertices in the renderer's layout,
joints and weights, tangents computed at build time for normal maps),
materials (factors, maps, sampler), images (decoded by `Images.decode`
when loaded), cameras, lights, skins, morph targets, animations (`model.clip(name)`,
playing on the nodes `instantiate` made) and the hierarchy.

Big files or loading screens: `Model.of(path, Lazy)` is an `Asset` of the
same typed model, loaded in the background (`asset.then(m -> ...)`,
`asset.ready`); `Model.load(path)` loads a path known only at run time.
Loads advance in `Assets.poll()`, which `Stages.frame` calls.

## Animation

```haxe
var made = [];
var root = hero.instantiate(world, device, null, made);   // made: the glTF nodes by index
var animator = new Animator(made);
animator.play(hero.clip(hero.animations.Run), {loop: true, fade: 0.2});
// each simulation step:
animator.update(dt);
```

Clips are glTF's keyframes (translation, rotation, scale; step, linear,
cubic spline). Skinned glTF meshes deform with their joints (a `Skin` per
instance, joint matrices in a texture); `examples/skinned.glb` is a
generated two-joint sample.

## Input

```haxe
var actions = new Actions();
actions.bind("jump", Key(0x20)).bind("jump", Region(0.75, 0.5, 1, 1));   // Space, or the screen's lower right
actions.bind("moveX", KeyAxis(0xFF51, 0xFF53));                         // the arrows
App.run(frame, e -> actions.event(e));
// each simulation step:
actions.step();
if (actions.pressed("jump")) ...;
var x = actions.axis("moveX");
```

## Debugging

`FrameStats` keeps the last frames' times and the renderer's counts;
`Overlay` draws them over the frame with `@hxmc/ui`'s drawn renderer (put
`packages/ui/src` and `packages/text/src` on the class path where it is
used).

## Fast refresh

`HotWorld.keep(world, key)`, after the world is made: under `hxmc dev` the
old build's transforms are put back by node path; nothing without
`-D hxmc.dev`.

## Rendering

```haxe
var renderer = new Renderer(device);
new GltfScene(Gltf.parse(Asset.embed("sample.glb")), device).instantiate(world);
// in the frame:
renderer.draw(enc, world, camera);   // one pass into the frame
```

The renderer extracts the world's meshes (`MeshRenderer`) into a draw
list (shown nodes inside the view, sorted by pipeline and material), then
records it with `PbrShader`: glTF's metallic-roughness model, the world's
first directional `Light` and up to four point lights
(`Light.pointLight(color, intensity, range)`, `Light.spot(...)`; a world without lights:
`renderer.sun*`), a sky-and-ground
ambient, ACES tone mapping, sRGB output. Nodes drawing the same primitive are drawn in one instanced call
(`renderer.instancing`, on by default). See-through materials (`material.blend`, glTF's alphaMode BLEND) are drawn after the opaque ones, farthest first. Shadows are opted in:
`renderer.use(new Shadows(device))` (one shadow map for the directional
light, fitted to the casters, filtered 3x3; `Shadows.cascaded(device, size, split)`:
two cascades, the first sharp over the camera's view up to `split`
metres). `Shapes.box`, `sphere` and
`plane` make meshes in code. Skinned meshes need
`renderer.use(new Skinning(device))`; materials' normal maps need
`renderer.use(new NormalMaps(device))`, made before the models load (they
get tangents: the file's, else computed); `renderer.use(new Sky(device))` draws
a sky behind the scene; `renderer.use(Environment.fromImage(device, mime, bytes))`
an equirectangular image behind it that also lights it (image-based ambient and reflections); `renderer.use(new Particles(device))` draws the
world's `Emitter`s (simulated by `Particles.update(world, dt)`). Programs draw at injection points:
`renderer.inject(BeforeOpaque | AfterOpaque | AfterPass, (enc, frame) -> ...)`; features reach the renderer through
`RenderFeature`, so unused ones are not linked.

`examples/sample.glb` (and `skinned.glb`, `textured.glb`, `normals.glb`) is generated by `test/SampleModel.hx` (MIT).

Tests: `test/SceneTest.hx`, `test/GltfTest.hx` and the frames of
`test/Scenes.hx` against `test/<scene>.png` (`make 3d-check`, natively;
`make 3d-web-check`, WebGPU and WebGL2 in Chromium).
