-- Per-class Explorer icons. GENERATED DATA -- do not hand-edit the map.
--
-- Studio-style class icons come from one spritesheet addressed by a ClassName
-- to tile-index map. The sheet and map are adapted from the Dex explorer's dark
-- set: a 32px grid, 18 tiles per row. A class the sheet does not name falls back
-- to the generic Service or object (Placeholder) tile, so a new or executor-only
-- class still gets an icon instead of an empty square. If the sheet asset fails to
-- load the label just stays transparent, so callers draw a neutral slot under it.
return function(env)
	local M = {}

	M.sheet = "rbxassetid://135148380892747"
	M.tile = 32
	M.columns = 18

	-- ClassName -> 1-based tile index.
	local INDEX = {
		["Accessory"] = 1, ["Actor"] = 2, ["AdGui"] = 3, ["AdPortal"] = 4, ["AirController"] = 5,
		["AlignOrientation"] = 6, ["AlignPosition"] = 7, ["AngularVelocity"] = 8, ["Animation"] = 9,
		["AnimationConstraint"] = 10, ["AnimationController"] = 11, ["AnimationFromVideoCreatorService"] = 12,
		["Animator"] = 13, ["ArcHandles"] = 14, ["Atmosphere"] = 15, ["Attachment"] = 16, ["AudioAnalyzer"] = 17,
		["AudioChannelMixer"] = 18, ["AudioChannelSplitter"] = 19, ["AudioChorus"] = 20, ["AudioCompressor"] = 21,
		["AudioDeviceInput"] = 22, ["AudioDeviceOutput"] = 23, ["AudioDistortion"] = 24, ["AudioEcho"] = 25,
		["AudioEmitter"] = 26, ["AudioEqualizer"] = 27, ["AudioFader"] = 28, ["AudioFilter"] = 29,
		["AudioFlanger"] = 30, ["AudioGate"] = 31, ["AudioLimiter"] = 32, ["AudioListener"] = 33,
		["AudioPitchShifter"] = 34, ["AudioPlayer"] = 35, ["AudioRecorder"] = 36, ["AudioReverb"] = 37,
		["AudioTextToSpeech"] = 38, ["AuroraScript"] = 39, ["AvatarEditorService"] = 40, ["AvatarSettings"] = 41,
		["Backpack"] = 42, ["BallSocketConstraint"] = 43, ["BasePlate"] = 44, ["Beam"] = 45, ["BillboardGui"] = 46,
		["BindableEvent"] = 47, ["BindableFunction"] = 48, ["BlockMesh"] = 49, ["BloomEffect"] = 50,
		["BlurEffect"] = 51, ["BodyAngularVelocity"] = 52, ["BodyColors"] = 53, ["BodyForce"] = 54,
		["BodyGyro"] = 55, ["BodyPosition"] = 56, ["BodyThrust"] = 57, ["BodyVelocity"] = 58, ["Bone"] = 59,
		["BoolValue"] = 60, ["BoxHandleAdornment"] = 61, ["Breakpoint"] = 62, ["BrickColorValue"] = 63,
		["BubbleChatConfiguration"] = 64, ["Buggaroo"] = 65, ["CFrameValue"] = 68, ["Camera"] = 66,
		["CanvasGroup"] = 67, ["ChannelTabsConfiguration"] = 69, ["CharacterControllerManager"] = 70,
		["CharacterMesh"] = 71, ["Chat"] = 72, ["ChatInputBarConfiguration"] = 73,
		["ChatWindowConfiguration"] = 74, ["ChorusSoundEffect"] = 75, ["Class"] = 76, ["Cleanup"] = 77,
		["ClickDetector"] = 78, ["ClientReplicator"] = 79, ["ClimbController"] = 80, ["Clouds"] = 81,
		["Color"] = 82, ["Color3Value"] = 284, ["ColorCorrectionEffect"] = 83, ["CompressorSoundEffect"] = 84,
		["ConeHandleAdornment"] = 85, ["Configuration"] = 86, ["Constant"] = 87, ["Constructor"] = 88,
		["Controller"] = 89, ["CoreGui"] = 90, ["CornerWedgePart"] = 91, ["CylinderHandleAdornment"] = 92,
		["CylindricalConstraint"] = 93, ["Decal"] = 94, ["DepthOfFieldEffect"] = 95, ["Dialog"] = 96,
		["DialogChoice"] = 97, ["DistortionSoundEffect"] = 98, ["DragDetector"] = 99, ["EchoSoundEffect"] = 100,
		["EditableImage"] = 101, ["EditableMesh"] = 102, ["Enum"] = 103, ["EnumMember"] = 104,
		["EqualizerSoundEffect"] = 105, ["Event"] = 106, ["Explosion"] = 107, ["FaceControls"] = 108,
		["Field"] = 109, ["File"] = 110, ["Fire"] = 111, ["FlangeSoundEffect"] = 112, ["Folder"] = 113,
		["ForceField"] = 114, ["Frame"] = 115, ["Function"] = 116, ["GameSettings"] = 117,
		["GroundController"] = 118, ["Handles"] = 119, ["HapticEffect"] = 120, ["HapticService"] = 121,
		["HeightmapImporterService"] = 122, ["Highlight"] = 123, ["HingeConstraint"] = 124, ["Humanoid"] = 125,
		["HumanoidDescription"] = 126, ["IKControl"] = 127, ["ImageButton"] = 128, ["ImageHandleAdornment"] = 129,
		["ImageLabel"] = 130, ["InputAction"] = 131, ["InputBinding"] = 132, ["InputContext"] = 133,
		["IntValue"] = 284, ["Interface"] = 134, ["IntersectOperation"] = 135, ["Keyword"] = 136,
		["Lighting"] = 137, ["LineForce"] = 139, ["LineHandleAdornment"] = 140, ["LinearVelocity"] = 138,
		["LocalFile"] = 141, ["LocalScript"] = 144, ["LocalizationService"] = 142, ["LocalizationTable"] = 143,
		["MaterialService"] = 145, ["MaterialVariant"] = 146, ["MemoryStoreService"] = 147, ["MeshPart"] = 148,
		["Meshparts"] = 149, ["MessagingService"] = 150, ["Method"] = 151, ["Model"] = 152, ["Modelgroups"] = 153,
		["Module"] = 154, ["ModuleScript"] = 155, ["Motor6D"] = 156, ["NegateOperation"] = 157,
		["NetworkClient"] = 158, ["NoCollisionConstraint"] = 159, ["NumberValue"] = 284, ["ObjectValue"] = 284,
		["Operator"] = 160, ["PackageLink"] = 161, ["Pants"] = 162, ["Part"] = 163, ["ParticleEmitter"] = 164,
		["Path2D"] = 165, ["PathfindingLink"] = 166, ["PathfindingModifier"] = 167, ["PathfindingService"] = 168,
		["PitchShiftSoundEffect"] = 169, ["Place"] = 170, ["Placeholder"] = 171, ["Plane"] = 172,
		["PlaneConstraint"] = 173, ["Player"] = 174, ["Players"] = 175, ["PluginGuiService"] = 176,
		["PointLight"] = 177, ["PrismaticConstraint"] = 178, ["Property"] = 179, ["ProximityPrompt"] = 180,
		["PublishService"] = 181, ["RayValue"] = 284, ["Reference"] = 182, ["RemoteEvent"] = 183,
		["RemoteFunction"] = 184, ["RenderingTest"] = 185, ["ReplicatedFirst"] = 186,
		["ReplicatedScriptService"] = 187, ["ReplicatedStorage"] = 188, ["ReverbSoundEffect"] = 189,
		["RigidConstraint"] = 190, ["RobloxPluginGuiService"] = 191, ["RocketPropulsion"] = 192,
		["RodConstraint"] = 193, ["RopeConstraint"] = 194, ["Rotate"] = 195, ["ScreenGui"] = 196, ["Script"] = 197,
		["ScrollingFrame"] = 198, ["Seat"] = 199, ["Selected_Workspace"] = 200, ["SelectionBox"] = 201,
		["SelectionSphere"] = 202, ["ServerScriptService"] = 203, ["ServerStorage"] = 204, ["Service"] = 205,
		["Shirt"] = 206, ["ShirtGraphic"] = 207, ["SkinnedMeshPart"] = 208, ["Sky"] = 209, ["Smoke"] = 210,
		["Snap"] = 211, ["Snippet"] = 212, ["SocialService"] = 213, ["Sound"] = 214, ["SoundEffect"] = 215,
		["SoundGroup"] = 216, ["SoundService"] = 217, ["Sparkles"] = 218, ["SpawnLocation"] = 219,
		["SpecialMesh"] = 220, ["SphereHandleAdornment"] = 221, ["SpotLight"] = 222, ["SpringConstraint"] = 223,
		["StandalonePluginScripts"] = 224, ["StarterCharacterScripts"] = 225, ["StarterGui"] = 226,
		["StarterPack"] = 227, ["StarterPlayer"] = 228, ["StarterPlayerScripts"] = 229, ["StringValue"] = 284,
		["Struct"] = 230, ["StyleDerive"] = 231, ["StyleLink"] = 232, ["StyleRule"] = 233, ["StyleSheet"] = 234,
		["SunRaysEffect"] = 235, ["SurfaceAppearance"] = 236, ["SurfaceGui"] = 237, ["SurfaceLight"] = 238,
		["SurfaceSelection"] = 239, ["SwimController"] = 240, ["TaskScheduler"] = 241, ["Team"] = 242,
		["Teams"] = 243, ["Terrain"] = 244, ["TerrainDetail"] = 245, ["TestService"] = 246, ["TextBox"] = 247,
		["TextBoxService"] = 248, ["TextButton"] = 249, ["TextChannel"] = 250, ["TextChatCommand"] = 251,
		["TextChatService"] = 252, ["TextLabel"] = 253, ["TextString"] = 254, ["Texture"] = 255, ["Tool"] = 256,
		["Torque"] = 257, ["TorsionSpringConstraint"] = 258, ["Trail"] = 259, ["TremoloSoundEffect"] = 260,
		["TrussPart"] = 261, ["TypeParameter"] = 262, ["UGCValidationService"] = 263,
		["UIAspectRatioConstraint"] = 264, ["UICorner"] = 265, ["UIDragDetector"] = 266, ["UIFlexItem"] = 267,
		["UIGradient"] = 268, ["UIGridLayout"] = 269, ["UIListLayout"] = 270, ["UIPadding"] = 271,
		["UIPageLayout"] = 272, ["UIScale"] = 273, ["UISizeConstraint"] = 274, ["UIStroke"] = 275,
		["UITableLayout"] = 276, ["UITextSizeConstraint"] = 277, ["UnionOperation"] = 278, ["Unit"] = 279,
		["UniversalConstraint"] = 280, ["UnreliableRemoteEvent"] = 281, ["UpdateAvailable"] = 282,
		["UserService"] = 283, ["VRService"] = 296, ["Value"] = 284, ["Variable"] = 285, ["Vector3Value"] = 284,
		["VectorForce"] = 286, ["VehicleSeat"] = 287, ["VideoDisplay"] = 288, ["VideoFrame"] = 289,
		["VideoPlayer"] = 290, ["ViewportFrame"] = 291, ["VirtualUser"] = 292, ["VoiceChannel"] = 293,
		["VoiceChatService"] = 295, ["Voicechat"] = 294, ["WedgePart"] = 297, ["Weld"] = 298,
		["WeldConstraint"] = 299, ["Wire"] = 300, ["WireframeHandleAdornment"] = 301, ["Workspace"] = 302,
		["WorldModel"] = 303, ["WrapDeformer"] = 304, ["WrapLayer"] = 305, ["WrapTarget"] = 306,
		["BasePart"] = 163, ["AnimationTrack"] = 9, ["Keyframe"] = 9, ["KeyframeSequence"] = 9,
		["Motor"] = 156, ["ManualWeld"] = 298, ["PostProcessEffect"] = 83,
	}
	M.index = INDEX

	local PLACEHOLDER = INDEX.Placeholder or 171
	local SERVICE = INDEX.Service or 205

	-- Zero-based tile for a class, resolving the unknown to a sensible default.
	local function tileFor(className, isService)
		local n = className and INDEX[className]
		if not n then
			if isService or (type(className) == "string" and className:sub(-7) == "Service") then n = SERVICE
			else n = PLACEHOLDER end
		end
		return n - 1
	end
	M.tileFor = tileFor

	-- The (offset, size) rectangle into the sheet for a class.
	function M.rect(className, isService)
		local tile = tileFor(className, isService)
		return Vector2.new(M.tile * (tile % M.columns), M.tile * math.floor(tile / M.columns)), Vector2.new(M.tile, M.tile)
	end

	-- Point an existing ImageLabel at a class tile. Safe to call every render.
	function M.paint(image, className, isService)
		if not image then return end
		local offset, size = M.rect(className, isService)
		if image.Image ~= M.sheet then image.Image = M.sheet end
		image.ImageRectOffset, image.ImageRectSize = offset, size
	end

	return M
end
