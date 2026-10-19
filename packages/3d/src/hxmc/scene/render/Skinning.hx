package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.scene.Node;

// Skinned meshes drawn, opted in (renderer.use(new Skinning(device))):
// PbrSkinnedShader's pipelines, each frame's joint matrices (Skin.update)
// and their binding. Without it the renderer leaves skinned primitives
// out, and a program links no skinning shader.
class Skinning implements RenderFeature implements RenderFeature.SkinSource {
	final device:Device;
	final plain:Pipeline;
	final double:Pipeline;
	final slotList:Array<Int>;
	final info = Bytes.alloc(16);
	final nearest:Sampler;

	public function new(device:Device) {
		this.device = device;
		plain = device.createPipeline(PbrSkinnedShader.pipeline({cull: Back, depthCompare: Less, depthWrite: true}));
		double = device.createPipeline(PbrSkinnedShader.pipeline({cull: None, depthCompare: Less, depthWrite: true}));
		slotList = Renderer.slotsOf(PbrSkinnedShader.uniforms, PbrSkinnedShader.textures);
		nearest = device.createSampler({filter: Nearest, wrap: Clamp});
	}

	public function attach(renderer:Renderer)
		@:privateAccess renderer.skinSource = this;

	public function prepare(node:Node):Bool {
		var skin = Skin.of(node);
		if (skin == null) return false;
		skin.update(node);
		return true;
	}

	public function pipeline(doubleSided:Bool):Pipeline
		return doubleSided ? double : plain;

	public function slots():Array<Int>
		return slotList;

	var shadow:Null<Pipeline>;
	var shadowSlotList:Array<Int> = [];

	public function shadowPipeline():Pipeline {
		if (shadow == null) {
			var d = ShadowSkinnedShader.pipeline({cull: None, depthCompare: Less, depthWrite: true});
			d.colorFormat = R32F;
			d.depthFormat = Depth32F;
			shadow = device.createPipeline(d);
			function u(name:String):Int {
				for (b in ShadowSkinnedShader.uniforms)
					if (b.name == name) return b.binding;
				return -1;
			}
			var t = -1;
			for (b in ShadowSkinnedShader.textures)
				if (b.name == "jointMatrices") t = b.binding;
			// (in bind's order: 5 the skin's block, 6 its joints; 0 the caster)
			shadowSlotList = [u("ShadowCaster"), -1, -1, -1, -1, u("PbrSkinInfo"), t];
		}
		return shadow;
	}

	public function shadowSlots():Array<Int>
		return shadowSlotList;

	public function bind(enc:Encoder, slots:Array<Int>, node:Node) {
		var skin = Skin.of(node);
		info.setFloat(0, skin.joints.length);
		enc.setUniforms(slots[5], info);
		enc.setTexture(slots[6], skin.texture, nearest);
	}
}
