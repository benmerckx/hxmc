package hxmc.scene.render;

import hxmc.gfx.*;

// Normal maps drawn, opted in (renderer.use(new NormalMaps(device))):
// PbrNormalShader's pipelines for primitives with tangents whose material
// has a normalTexture (glTF's, tangents from the file or computed when
// loaded: models loaded after it is made). Without it those primitives are drawn with the standard shader
// (their tangents unread, the map ignored), and a program links no
// normal-map shader. Skinned and instanced draws keep their own shaders
// (the map ignored) for now.
class NormalMaps implements RenderFeature implements RenderFeature.NormalSource {
	// (the vertices as the standard layout's, the tangents in a second buffer)
	static final LAYOUT:Array<VertexBufferLayout> = [
		{
			stride: 32,
			attributes: [{location: 0, format: Float3, offset: 0}, {location: 1, format: Float3, offset: 12}, {location: 2, format: Float2, offset: 24}]
		},
		{stride: 16, attributes: [{location: 3, format: Float4, offset: 0}]}
	];

	final plain:Pipeline;
	final double:Pipeline;
	final slotList:Array<Int>;

	public function new(device:Device) {
		// (models loaded from now on get their tangents)
		VertexData.tangentsFrom = VertexData.computeTangents;
		var d = PbrNormalShader.pipeline({cull: Back, depthCompare: Less, depthWrite: true});
		d.layout = LAYOUT;
		plain = device.createPipeline(d);
		d = PbrNormalShader.pipeline({cull: None, depthCompare: Less, depthWrite: true});
		d.layout = LAYOUT;
		double = device.createPipeline(d);
		slotList = Renderer.slotsOf(PbrNormalShader.uniforms, PbrNormalShader.textures);
	}

	public function attach(renderer:Renderer)
		@:privateAccess renderer.normalSource = this;

	public function pipeline(doubleSided:Bool):Pipeline
		return doubleSided ? double : plain;

	public function slots():Array<Int>
		return slotList;
}
