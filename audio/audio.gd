extends Node
## Global audio service. Register as an autoload named "Audio":
##   Project Settings > Globals > Autoload > path res://scripts/audio.gd, name Audio.
##
##   Audio.play(&"player/jump")                       one-shot, not positional
##   Audio.play_at(&"traps/crusher_slam", position)   one-shot, positional (pans/fades with distance)
##   Audio.make_loop(&"traps/sawwheel_hum")           looping per-object sound: add_child() the result
##   Audio.play_music(&"objon")                       crossfades from whatever was playing
##
## SOUND IDS come from the folder layout under res://audio/, no registration step:
##   folder/name, lowercased, spaces -> underscores, TRAILING DIGITS = variant number.
##   audio/player/jump1.wav ... jump5.wav  ->  &"player/jump" (one id, 5 variants, picked at random
##   with slight pitch/volume jitter). A file whose name doesn't end in digits is a single-variant id.
##   Don't end a *distinct* sound's name in a digit (laser2.wav would be read as variant 2 of "laser").
##   audio/music/ is separate: ids are the plain file name, no variant handling (music/objon.ogg -> &"objon").
##   If a group of numbered files are actually DIFFERENT sounds (collectible1-3), play them by number
##   (variant argument) or rename them to distinct names; a plain play() would pick one at random.
##
## A play call with an id that has no file:
##   - is silently skipped if the id is in PLANNED below (sound not authored yet; the hook is already
##     in the code, so adding the file is all that's needed);
##   - otherwise push_warning()s once — that's a typo, unlike the original's silent no-op.

const AUDIO_ROOT := "res://audio"
const MUSIC_FOLDER := "music"
const AUDIO_EXTENSIONS: PackedStringArray = ["wav", "ogg", "mp3"]

const SFX_BUS := &"SFX"
const MUSIC_BUS := &"Music"

const POOL_SIZE_POSITIONAL := 16
const POOL_SIZE_FLAT := 8

# AudioStreamPlayer2D's default max_distance is 2000px. At this project's 4x camera zoom the whole
# screen is only ~320px wide, so at the default nothing would audibly fade with distance.
const MAX_DISTANCE := 280.0

const RETRIGGER_GUARD_MSEC := 30  # the same id twice within this window is dropped (stops stacked, louder duplicates)
const RANDOM_PITCH := 1.06        # AudioStreamRandomizer pitch jitter (1.0 = none)
const RANDOM_VOLUME_DB := 1.0     # AudioStreamRandomizer volume jitter (0.0 = none)

# Per-id mixing without re-exporting audio: base volume in dB, added to any per-call volume_db.
# Ids not listed play at 0 dB. The values below are starting guesses, not measured.
const TUNING := {
	&"player/footstep": {"volume_db": -6.0},
}

# Sounds the code already calls for but that have no file yet. Add the file under res://audio/<folder>/
# and the hook starts working; nothing else to change. Remove an id from here once its file exists
# (harmless if you forget — a present file always wins). The debug console prints what's still missing.
const PLANNED: Array[StringName] = [
	&"player/land",                    # touching down after a fall (volume scales with fall speed)
	&"player/surf_start",              # pulling the board out and mounting it
	&"player/surf_loop",               # LOOP: the board on the ground; pitch follows the speed, silent in the air
	&"player/surf_bowl",               # the board bowling something over, at the target
	&"player/surf_water_loop",         # LOOP: the board skimming a basin; pitch follows the speed, silent off the surface
	&"player/surf_splash",             # the board touching a basin's surface (skimming starts), at the board
	&"player/surf_steam_loop",         # LOOP: steam lifting the board; volume follows the lift, silent without it
	&"player/hang",                    # grabbing a ledge
	&"player/mantle",                  # pulling up over a ledge
	&"player/climb_step",              # ladder, frame-synced (see FRAME_SOUNDS in player.gd)
	&"player/win",                     # start of the victory dance
	&"traps/sawwheel_hum",             # LOOP, attached to the saw (Audio.make_loop)
	&"traps/crusher_extend",
	&"traps/crusher_slam",
	&"traps/crusher_retract",
	&"traps/crusher_jam",             # a metal block stalling a crusher: the jam latching (once per latch), at the spike
	&"traps/laser_boil",              # a laser starting to boil a pool (once per start of contact, per turret), at the turret
	&"traps/arc_fire",               # an arc turret firing an arc, at the muzzle
	&"traps/arc_reflect",            # an arc bouncing off a mirror, at the mirror
	&"traps/arc_fizzle",             # an arc spent on a wall or the player, at the point
	&"traps/cannon_fire",
	&"interactive/drop_platform_warning",  # start of the 3-flash tell
	&"interactive/drop_platform_fall",
	&"interactive/jump_pad",
	&"interactive/ice_melt",           # the original's "Melt"
	&"interactive/steel_solidify",
	&"interactive/metal_melt",         # metal block bursting into slag
	&"interactive/metal_splash",       # metal block first touching slag or water at speed
	&"interactive/metal_shunt",        # metal block kicked (heavy scrape; quieter/duller than ice_shunt)
	&"interactive/seesaw_creak",      # LOOP, at the see-saw's pivot (RotatingBody); volume and pitch follow its angular speed
	&"interactive/seesaw_thud",       # the see-saw hitting an angle limit (louder the faster it arrives)
	&"interactive/swing_creak",       # LOOP, at the swing's pivot (Swing, a RotatingBody); volume and pitch follow its angular speed
	&"interactive/swing_thud",        # the swing hitting an angle limit (rare: pumping tapers off before it)
	&"enemies/grunt_hit",             # a kick landing on a grunt (a grunt's grunt)
	&"enemies/grunt_bowled",          # a grunt knocked out by a surfer, thrown and spinning
	&"enemies/grunt_windup",          # a grunt starting its windup (the telegraph, hammer rising), at the grunt
	&"enemies/grunt_swing",           # a grunt's hammer coming down (start of the live swing), at the grunt
	&"enemies/crawler_flip",          # a tread crawler flipped onto its back (a stomp or a kick), at the crawler
	&"enemies/crawler_hit",           # a kick landing on a flipped tread crawler without destroying it, at the crawler
	&"enemies/crawler_bowled",        # a tread crawler knocked out by a surfer, thrown and spinning
	&"enemies/mine_arm",              # a proximity mine arming (the fuse starts), at the mine
	&"enemies/mine_explode",          # a proximity mine going off, at the mine
	&"enemies/mine_kick",             # a proximity mine kicked, sliding off, at the mine
	&"enemies/railbot_drip",          # a rail bot letting a spark drop, at the nozzle
	&"enemies/railbot_hit",           # a rail bot taking a hit without being destroyed, at the bot
	&"interactive/basin_zap",         # a spark reaching a basin's water and electrifying it, at the surface
	&"interactive/mirror_rotate",
	&"interactive/laser_receiver_on",   # a laser receiver powering (the beam reached it), at the receiver
	&"interactive/bullet_target_hit",    # a cannon bullet hitting a bullet target (every hit), at the target
	&"interactive/laser_receiver_off",  # a laser receiver losing power (after its hold time), at the receiver
	&"interactive/arc_receiver_on",       # an arc receiver powering (an arc struck it), at the receiver
	&"interactive/arc_receiver_off",      # an arc receiver losing power (its hold time ran out after the last arc), at the receiver
	&"interactive/button_press",       # button turning on (also each press of a toggle button)
	&"interactive/button_release",     # button turning off
	&"interactive/weight_plate_press",   # a weight plate powering (the weight reached its threshold), at the plate
	&"interactive/weight_plate_release", # a weight plate losing power (after its hold time), at the plate
	&"interactive/angle_sensor_on",     # an angle sensor powering (its body tilted past the threshold), at the sensor
	&"interactive/angle_sensor_off",    # an angle sensor losing power (the body came back past the hysteresis), at the sensor
	&"interactive/basin_sensor_on",     # a basin sensor powering (its basin reached the fill, crust or column reading), at the sensor
	&"interactive/basin_sensor_off",    # a basin sensor losing power (after its hysteresis and hold time), at the sensor
	&"interactive/speed_trap_flash",    # the camera flashing on any read (every crossing it reads), at the trap
	&"interactive/speed_trap_pass",     # a reading at or above the threshold: the trap powers
	&"interactive/speed_trap_fail",     # a reading below the threshold
	&"interactive/barrier_break",      # a breakable barrier broken by a fast surf, at the barrier
	&"interactive/door_open",          # door starting to open (not played while a blocked close waits)
	&"interactive/door_close",         # door starting to close
	&"interactive/finish_unlock",     # finish turning from locked to unlocked (not at load)
	&"interactive/finish_open",       # player entering the unlocked finish
	&"interactive/checkpoint",        # a checkpoint being activated (start of its light-up animation)
	&"collectibles/medkit",
	&"traps/spikes_hit",             # a spike tile hurting the player, at the tile
	&"ui/menu_open",                  # the pause menu opening
	&"ui/menu_close",                 # the pause menu closing (resume)
	&"ui/menu_select",                # a menu button being pressed
]

# Registry, filled by _scan_audio()
var _sfx: Dictionary = {}    # StringName id -> {"random": AudioStreamRandomizer, "variants": Array[AudioStream]}
var _music: Dictionary = {}  # StringName id -> AudioStream

var _positional_pool: Array = []  # AudioStreamPlayer2D; front = least recently used
var _flat_pool: Array = []        # AudioStreamPlayer
var _last_played: Dictionary = {}
var _warned: Dictionary = {}

var _music_players: Array[AudioStreamPlayer] = []
var _music_active: AudioStreamPlayer = null
var _music_id: StringName = &""
var _music_tween: Tween


## A looping sound owned by one object (saw hum, laser beam, conveyor...). Returned unparented:
## add_child() it to the object, then call start(). Safe to use before the sound file exists.
class LoopPlayer extends AudioStreamPlayer2D:
	func start() -> void:
		if stream != null and not playing:
			play()

	func stop_loop() -> void:
		stop()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # music and in-flight sounds keep going while the tree is paused
	_ensure_bus(SFX_BUS)
	_ensure_bus(MUSIC_BUS)
	_build_pools()
	_scan_audio()
	_report()


# --- public API ----------------------------------------------------------------------------

func play(id: StringName, volume_db: float = 0.0, variant: int = -1) -> void:
	_play(id, null, volume_db, variant)


## variant >= 0 plays that specific numbered variant (0 = the first, sorted by filename number)
## with no random jitter, e.g. to escalate a pickup sound; -1 (default) picks randomly.
func play_at(id: StringName, position: Vector2, volume_db: float = 0.0, variant: int = -1) -> void:
	_play(id, position, volume_db, variant)


func make_loop(id: StringName, volume_db: float = 0.0) -> LoopPlayer:
	var loop_player := LoopPlayer.new()
	loop_player.bus = SFX_BUS
	loop_player.max_distance = MAX_DISTANCE
	loop_player.volume_db = volume_db + _tuned_db(id)
	var stream := _resolve_stream(id, 0)  # first variant, no randomizer: a randomizer can't loop
	if stream != null:
		loop_player.stream = _as_loop(stream, id)
	return loop_player


func play_music(id: StringName, fade_time: float = 1.0) -> void:
	if id == _music_id and _music_active != null and _music_active.playing:
		return
	var stream: AudioStream = _music.get(id)
	if stream == null:
		_warn_unknown(id, "music track")
		return
	_music_id = id
	if _music_tween != null:
		_music_tween.kill()

	var outgoing := _music_active
	var incoming: AudioStreamPlayer = _music_players[1] if outgoing == _music_players[0] else _music_players[0]
	incoming.stop()  # discards a half-faded leftover if tracks were switched quickly
	incoming.stream = stream
	incoming.volume_db = -80.0
	incoming.play()
	_music_active = incoming

	_music_tween = create_tween().set_parallel(true)
	_music_tween.tween_property(incoming, "volume_db", _tuned_db(id), fade_time)
	if outgoing != null and outgoing.playing:
		_music_tween.tween_property(outgoing, "volume_db", -80.0, fade_time)
		_music_tween.chain().tween_callback(outgoing.stop)


func stop_music(fade_time: float = 1.0) -> void:
	_music_id = &""
	if _music_tween != null:
		_music_tween.kill()
	var fading := _music_active
	_music_active = null
	for music_player in _music_players:
		if music_player != fading:
			music_player.stop()  # anything left over from a killed crossfade
	if fading == null:
		return
	_music_tween = create_tween()
	_music_tween.tween_property(fading, "volume_db", -80.0, fade_time)
	_music_tween.tween_callback(fading.stop)


# --- setup ---------------------------------------------------------------------------------

func _ensure_bus(bus_name: StringName) -> void:
	# Created in code if missing. These runtime buses don't appear in the editor's Audio panel; if
	# you'd rather author them there, create buses named "SFX" and "Music" and this does nothing.
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, &"Master")


func _build_pools() -> void:
	for i in POOL_SIZE_POSITIONAL:
		var pooled := AudioStreamPlayer2D.new()
		pooled.bus = SFX_BUS
		pooled.max_distance = MAX_DISTANCE
		add_child(pooled)
		_positional_pool.append(pooled)
	for i in POOL_SIZE_FLAT:
		var pooled := AudioStreamPlayer.new()
		pooled.bus = SFX_BUS
		add_child(pooled)
		_flat_pool.append(pooled)
	for i in 2:
		var music_player := AudioStreamPlayer.new()
		music_player.bus = MUSIC_BUS
		add_child(music_player)
		_music_players.append(music_player)


func _scan_audio() -> void:
	var folders := ResourceLoader.list_directory(AUDIO_ROOT)
	if folders.is_empty():
		push_warning("Audio: nothing found under %s — is the audio folder there?" % AUDIO_ROOT)
		return

	var variant_pattern := RegEx.create_from_string("^(.+?)(\\d+)$")
	var groups: Dictionary = {}  # id -> Array of [variant number, stream]
	var seen_paths: Dictionary = {}

	for entry in folders:
		if not entry.ends_with("/"):
			continue
		var folder: String = entry.trim_suffix("/")
		var folder_path := "%s/%s" % [AUDIO_ROOT, folder]
		for file in ResourceLoader.list_directory(folder_path):
			# some Godot versions/exports report imported files with a .import/.remap suffix
			var file_name: String = file.trim_suffix(".remap").trim_suffix(".import")
			if file_name.ends_with("/") or not AUDIO_EXTENSIONS.has(file_name.get_extension().to_lower()):
				continue
			var path := "%s/%s" % [folder_path, file_name]
			if seen_paths.has(path):
				continue
			seen_paths[path] = true
			var stream := load(path) as AudioStream
			if stream == null:
				push_warning("Audio: couldn't load %s" % path)
				continue

			var stem := _normalize(file_name.get_basename())
			if folder == MUSIC_FOLDER:
				_set_looping(stream)
				_music[StringName(stem)] = stream
				continue

			var base := stem
			var number := 0
			var match_result := variant_pattern.search(stem)
			if match_result != null:
				base = match_result.get_string(1)
				number = match_result.get_string(2).to_int()
			var id := StringName("%s/%s" % [_normalize(folder), base])
			if not groups.has(id):
				groups[id] = []
			groups[id].append([number, stream])

	for id in groups:
		var entries: Array = groups[id]
		entries.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		var variants: Array[AudioStream] = []
		var randomizer := AudioStreamRandomizer.new()
		randomizer.random_pitch = RANDOM_PITCH
		randomizer.random_volume_offset_db = RANDOM_VOLUME_DB
		for i in entries.size():
			variants.append(entries[i][1])
			randomizer.add_stream(i, entries[i][1])
		_sfx[id] = {"random": randomizer, "variants": variants}


func _report() -> void:
	if not OS.is_debug_build():
		return
	var missing: PackedStringArray = []
	for id in PLANNED:
		if not _sfx.has(id):
			missing.append(String(id))
	print("Audio: %d sound ids, %d music track(s). %d planned with no file yet: %s" % [
		_sfx.size(), _music.size(), missing.size(), ", ".join(missing)])


# --- internals -----------------------------------------------------------------------------

func _play(id: StringName, position: Variant, volume_db: float, variant: int) -> void:
	var stream := _resolve_stream(id, variant)
	if stream == null:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_played.get(id, -RETRIGGER_GUARD_MSEC)) < RETRIGGER_GUARD_MSEC:
		return
	_last_played[id] = now

	var db := volume_db + _tuned_db(id)
	if position is Vector2:
		var positional := _acquire(_positional_pool) as AudioStreamPlayer2D
		positional.global_position = position
		positional.stream = stream
		positional.volume_db = db
		positional.play()
	else:
		var flat := _acquire(_flat_pool) as AudioStreamPlayer
		flat.stream = stream
		flat.volume_db = db
		flat.play()


func _acquire(pool: Array) -> Node:
	# first idle player, else steal the least recently used; either way it moves to the back
	var chosen: Node = null
	for candidate in pool:
		if not candidate.playing:
			chosen = candidate
			break
	if chosen == null:
		chosen = pool[0]
	pool.erase(chosen)
	pool.append(chosen)
	return chosen


func _resolve_stream(id: StringName, variant: int) -> AudioStream:
	var entry: Dictionary = _sfx.get(id, {})
	if entry.is_empty():
		if not PLANNED.has(id):
			_warn_unknown(id, "sound id")
		return null
	if variant >= 0:
		var variants: Array = entry["variants"]
		return variants[variant % variants.size()]
	return entry["random"]


func _tuned_db(id: StringName) -> float:
	var tuning: Dictionary = TUNING.get(id, {})
	return tuning.get("volume_db", 0.0)


func _normalize(text: String) -> String:
	return text.strip_edges().to_lower().replace(" ", "_")


func _warn_unknown(id: StringName, kind: String) -> void:
	if _warned.has(id):
		return
	_warned[id] = true
	push_warning("Audio: unknown %s '%s' — typo, or no file under %s yet (planned sounds go in Audio.PLANNED)" % [kind, id, AUDIO_ROOT])


func _set_looping(stream: AudioStream) -> void:
	# for streams used only as music, so mutating the cached resource is fine
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


func _as_loop(stream: AudioStream, id: StringName) -> AudioStream:
	# for one-shot-capable streams: loop a COPY, so other users of the same cached file are unaffected
	if stream is AudioStreamOggVorbis:
		var ogg := stream.duplicate() as AudioStreamOggVorbis
		ogg.loop = true
		return ogg
	if stream is AudioStreamMP3:
		var mp3 := stream.duplicate() as AudioStreamMP3
		mp3.loop = true
		return mp3
	if stream is AudioStreamWAV:
		var wav := stream.duplicate() as AudioStreamWAV
		if wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
			return wav  # the file's Import settings already loop it; respect them
		# Loop the whole clip. loop_end is measured in sample frames, so it needs the frame size; only
		# plain 8/16-bit PCM is handled (Godot's default WAV import keeps 16-bit PCM).
		var sample_bytes := 0
		if wav.format == AudioStreamWAV.FORMAT_16_BITS:
			sample_bytes = 2
		elif wav.format == AudioStreamWAV.FORMAT_8_BITS:
			sample_bytes = 1
		if sample_bytes == 0:
			push_warning("Audio: '%s' is a compressed .wav, so it can't be looped from code — set Loop Mode: Forward in its Import tab, then Reimport" % id)
			return stream
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / (sample_bytes * (2 if wav.stereo else 1))
		return wav
	return stream
