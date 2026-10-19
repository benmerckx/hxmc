# @hxmc/3d-ui

`@hxmc/view`'s markup and signals on `@hxmc/3d`'s scene graph (Haxe package
`hxmc.scene.view`; the plan's reactive layer, docs/plans/3d.md). An
optional package: the 3D core knows nothing of it.

```haxe
// -D hxmc.view.renderer=hxmc.scene.view.SceneRenderer
var pos = signal(new Vec3(0, 1, 0));
var lit = signal(true);
SceneRenderer.device = device;
Render.render(<node name="lamp" position={pos}>
	<mesh shape="sphere" size={0.4} color={new Vec4(1, 0.8, 0.4, 1)}/>
	<Show when={lit}><light kind="point" intensity={6.0} range={8.0}/></Show>
</node>, SceneRenderer.root(world));
pos.value = new Vec3(1, 1, 0);   // the node moves: no reconciliation, no re-render
```

Elements: `node`, `mesh` (shape `box`, `sphere`, `plane`; size, color,
metallic, roughness), `light` (kind `directional`, `point`; color,
intensity, range), `camera` (fov, near, far); `position`, `rotation`,
`scale`, `name`, `visible` on all. Per-frame work goes through the frame
stages (`hxmc.scene.Stages`), not through signals.

A prototype: properties go through `setProperty` by name; typed
constructors per tag, checked when compiling, come next. A struct value
(`Vec3`, `Quat`) is bound through a `Signal` for now (hxmc does not yet
pass a closure returning one where a function of another type is
expected).

Tests: `test/SceneUiTest.hx` (`make 3d-check`).
