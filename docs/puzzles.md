# Puzzle primitives and concepts

The small reusable patterns (logic, spatial, timing, resource) that the current objects can build, and a catalogue of puzzle concepts that combine them. **The concepts are design proposals derived from the documented rules, not playtested**; one that leans on behaviour the docs only imply is marked **(untested)**, and the mark is removed once it has been tried in a level. What each object does, its knobs and its limits are in `level-design.md`; read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

Covers: Puzzle primitives (Logic; Spatial; Timing; Resource); Puzzle concepts (A. Light, mirrors and receivers; B. Water, slag and steam; C. Weight, balance and swinging; D. Momentum and the surf; E. Traversal and spatial; F. Timing, rhythm and traps; G. Enemies as mechanisms; H. Information, routing and pacing; I. Full-room recipes)

## Puzzle primitives

The atoms. Each can be built from the objects in the Object catalogue (`level-design.md`).

**Logic**
- **AND**: several sources on one target with `all_required`. Receivers and plates are best (steady). For arcs/bullets use TIMED latch.
- **OR**: several sources, default. Gives alternate solutions for free.
- **NOT**: `invert` on the device or target. A door that closes when you press the button.
- **Latch / memory**: TOGGLE button, TOGGLE bullet/arc target, a crust (never thins), a jam (latched until power cycle).
- **Timer**: TIMED button / speed trap `hold_time` / receiver `hold_time` / melting ice on a plate.
- **Counter / sequence**: a mirror turning one step per rising edge. Aim at the receiver only at step N.
- **Pulse**: MOMENTARY target; a cannon firing faster than `pulse_length` holds it on.
- **Analogue threshold with hysteresis**: angle sensor, basin sensor, weight plate. Can't chatter.
- **Clock**: crusher/arc/cannon/rail bot cycles with `phase_offset`; a motorized see-saw read by an angle sensor produces a square wave **(untested)**.

**Spatial**
- **Gate**: door, breakable barrier, crust, mirror-shielded beam.
- **Gap crossing**: catwalk hang, crust bridge, ice raft, slag raft, swing, rail slide, ramp-and-skim, pad.
- **Keyhole**: a corridor only a crouch/sneak fits, a catwalk only a hang passes, a door you can't hang from.
- **Weighted lever**: see-saw with a threshold sensor.
- **Aiming**: mirror steps, a tilted mirror see-saw, a moving platform with a mirror, liquid poured as a variable load.

**Timing**
- **Telegraphed cycle**: crusher (dwell windows), arc turret glow, rail bot glow, grunt windup.
- **Time-to-live**: ice (2 s in a beam), metal-on-slag (8 s), flipped crawler (4 s), drop platform (1 s), TIMED hold.
- **Race**: a TIMED button and a door/route you have to reach before it resets.

**Resource**
- **A block as tool**: shield, weight, bridge, plug, battery of mass.
- **A liquid as tool**: load, crust-maker, steam-maker, lift, aim.
- **Momentum as tool**: surf speed that is *banked* over a stretch and *spent* on a barrier, trap or launch.

## Puzzle concepts

Each concept lists **ingredients** and how it plays, then **twists** to scale difficulty. They're grouped by what the player has to *think about*. Many combine across groups; the last section has full-room recipes.

### A. Light, mirrors and receivers

**A1. Mirror relay.** *Laser turret + 2 to 4 mirrors + laser receiver + door.* The player kicks mirrors (45° steps) until the beam reaches the receiver. *Twists:* a mirror on a **moving platform** sweeps the beam, so the receiver only lights during a window (needs `hold_time` to bridge); a mirror the player can't reach is turned by a **button's rising edge** instead; set `kick_rotates` false on switch-owned mirrors; the beam crosses glass and catwalks so the solution can be visible from afar.

**A2. Combination lock.** *Mirror on power + a momentary button + receiver.* Each *click* (crouch while standing on the pad cycles it) advances the mirror one step; the receiver is lit only at the right step. The player has to count clicks from the layout. *Twists:* two mirrors on two buttons, both must align (AND of two receivers); a toggle button instead teaches that only rising edges count; a mirror past the receiver position forces going all the way around (8 steps).

**A3. Disposable shield.** *Laser + ice or metal block + a thing that must not be lit.* A block in a beam is a shield with a lifespan, and melting spawns liquid at its position. Ice gives about 2 s then a puddle (and refreezes when shaded). Metal gives about 3 s, then pours slag. *Twists:* the shield stands on a see-saw (the melt shifts the load); metal melts onto a lower basin and crusts it; the player must *carry* the shield forward by kicking it.

**A4. Beam-and-block race.** *Laser aimed at a block that holds a button/plate down.* The block melts and the plate releases, so a timer is built from the physics. *Twists:* a mirror lets the player re-aim the beam to buy time (shade it, let it cool); two blocks on one plate are required together.

**A5. Window receiver.** *Moving platform with a mirror, or a Stingbot crossing the beam.* The receiver lights briefly each pass. With a short `hold_time` the player has to be at the door when it's lit; with a longer one it's an easy gate. Stingbots flicker receivers behind them by design (their `hold_time` covers it). Used on purpose, a stingbot is a *clock*. **(untested)**

**A6. Arc ricochet.** *Arc turret + mirrors + arc receiver.* The arc is slow (220 px/s) and has finite range (480 px), so the path length matters. It passes enemies and the player's layer, so it can run through a room unseen. *Twists:* two arc receivers on TIMED latches (AND); `phase_offset` to stagger turrets; an arc that fizzles because the path is too long teaches range; water on the route electrifies the pool.

**A7. Shoot-through-a-wall.** *Glass wall + laser receiver on the far side.* Light is visible but unreachable until a door opens or a mirror is repositioned. Same for arcs. Reads well as a puzzle statement ("the receiver is right there").

### B. Water, slag and steam

**B1. Float up.** *Faucet + basin + ice block + a ledge above.* Fill the basin to float the block up to the ledge. Ice floats at about 80% submerged and follows the rising surface (even with riders). *Twists:* a metal block sinks, so it must be carried another way; `rest_fraction` past 1.0 means too heavy (a big block with riders sinks); a basin sensor opens a door at 50% fill and a drain brings the level back; riders are limited by `rider_load_tiles`.

**B2. Crust bridge.** *Slag basin + water faucet.* Pouring water on slag crusts it into a walkable slab and makes steam. The player has to pour enough, in the right place. Pre-filled slag you can't cross becomes a floor. *Twists:* water has to come from a melting ice block (laser); the crust makes steam that is a **surf lift** column for the next section; the steam rises into a ceiling gap and stops.

**B3. Under the crust.** *Crust + a drain + the crust underside hang.* Crust, then drain the liquid under it to open a void, then **hang and brachiate under the crust** across a hazard. The slag lake above is safe (crust), and the void below is the route. *Twists:* the void only exists while the drain is open; a basin sensor on CRUST powers the door that gives you access; a second basin chained after the first receives the overflow.

**B4. Slag raft.** *Slag basin + metal block + a gap.* Metal floats on slag but lasts about 8 s. Kick it across and ride. A tight timeline. *Twists:* ice dropped on the slag instead bursts to water and crusts instead (the other solution); the raft is needed to *carry a weight* across onto a plate; a tread crawler flipped as a stepping stone is a free third option.

**B5. Evaporation.** *Laser (boils_water) + boilable basin + basin sensor.* Boiling drains the pool, so a pool that blocks the way becomes passable. The sensor releases a door when it's empty. The faucet refills it, and the pool *settles where the beam meets the surface*. *Twists:* a faucet-refilled pool that never empties unless the beam stays on; steam from boiling lifts a surfer; slag is never boiled, so this only works on water.

**B6. Hydraulic scale.** *Water or slag poured onto a see-saw plank + angle sensor.* Liquid is load: water 1 per tile of volume, slag 3. A faucet pouring on one end tips the plank until the sensor trips. *Twists:* the plank has `mirror_surface` so the pour *aims a beam*; a laser melts an ice block on the plank so the load turns into water and keeps changing **(untested)**.

**B7. Wet run-up.** *Melting ice on a slope + a surf.* Melt ice at the top of a slope: the water flows down and wets the floor, raising surf top speed from 600 to 800 and reducing friction. A barrier with `break_speed` 700 can only be broken on wet ground. *Twists:* the laser has to be redirected to start the melt; the water has to reach the floor or it dries (decays 0.4 s after leaving).

**B8. Safe water.** *Rail bot spark or arc turret over a pool.* The pool is electrified for 1 s after each strike. The swim is possible only in the gaps between strikes, and the telegraph glow tells you when. *Twists:* the pool can't be skimmed while electrified, so a surf over it fails; `conducts_sparks` off on a decoy basin; the strike comes from a ricocheting arc and electrifies a pool far from the turret.

**B9. Relaxation oscillator.** *Basin + steady faucet + basin sensor FILL + drain faucet wired to the sensor.* The pool fills to 50%, the sensor opens the drain, it falls below the threshold minus hysteresis, the drain closes, and it refills. The result is a slow periodic signal driving doors, crushers, or a plate **(untested; the docs only guarantee one swing without inflow)**.

### C. Weight, balance and swinging

**C1. Counterweight.** *See-saw + metal block (weight 4 per tile) + angle sensor + door.* The player alone (weight 2) can't tip the plank, so the block must be positioned first and the player completes the load. *Twists:* the door only holds while the plank stays tipped, so something must be left on it; the plank's motor fights the player's weight and you only win while standing on the high end; the block is on the plank *and* the plate.

**C2. Plate budgeting.** *Weight plate with a threshold (e.g. 6) + blocks of several weights.* Weights: player 2, ice 1×1 = 1, metal 1×1 = 4 (a 2×1 metal is 8). The player needs to find a combination (metal block + player on top counts as stacked weight; 4 + 2 = 6). *Twists:* a plate under a melting ice block releases on its own (a timer); two plates wired AND; a plate that also *tips a see-saw* so the weight is spent twice.

**C3. Pump the swing.** *Swing + angle sensor on it + door.* The player grabs the bar and pumps with left/right until the arc passes the threshold. *Twists:* the sensor is on the *far* side so the player must release at the right moment; the arc crosses a spike pit; `free_rotation` for a full loop (the sensor is powered through that sector once per turn, so use a limited swing for a sensor); a moving platform under the arc.

**C4. Momentum into the swing.** *Surf ramp + swing.* A surfer in the air grabs the bar and passes the **whole surf speed** into the swing (400 px/s on a 64 px rod is about 6 rad/s), then releases to launch far past where a jump could go. *Twists:* the ±80° limit pins a fast catch and swings it back (use `free_rotation` for a big arc); a gem trail marks the release point.

**C5. Plank-as-ramp.** *See-saw on a surf route.* A tilted plank is a ramp from the low end, but the raised end is a lip that stops a fast surf like a wall. The player must arrive on the low side, or hit it when the plank is level, or make the plank level by standing a counterweight on it. Flat plank ends sit flush at extremes.

**C6. Motor and brake.** *Motorized see-saw + riders.* A heavy enough rider on the high side holds it against the stop. A see-saw that oscillates becomes a moving ramp/bridge the player times, and an angle sensor on it is a clock.

### D. Momentum and the surf

**D1. Banked speed.** *Downhill + flat + speed trap or barrier.* The level is designed so the *only* way to reach 450+ is a particular line (downhill matched, wet floor, a clean landing). *Twists:* a belt against the surfer is a speed tax (or a speed assist); a tilt-mismatched section silently drains speed; a pad on the line launches without a tilt penalty.

**D2. Speed trap door.** *Speed trap + door.* The trap reads a *surfer's* ground speed as they cross its line, and powers the door for `hold_time` seconds (5 default). The door is far, so the player must surf *and then run* before it closes. *Twists:* `hold_time` 0 = permanent; two traps in an AND with different thresholds; the line is across a pool, so skim at 180+ speed *and* arrive at 450+.

**D3. Barrier gauntlet.** *Breakable barriers with different `break_speed`s along a run.* The player must still be fast after paying friction. Mix `break_from` LEFT/RIGHT so you must approach from the right side. Barriers don't pay points, but enemies bowled between them do. *Twists:* the barrier blocks a laser beam, so smashing it opens the line of fire (and *lights a receiver* through the hole); the run continues into a launch.

**D4. Ice shove.** *Surf + ice block + weight plate far away.* The surf is a long-range kick: shove an ice block at speed and it slides up to about 18 tiles on its own to a distant plate, or into a mine cluster. *Twists:* a metal block moves much less per shove, a ledge dumps the block, a wall in front of the block refuses the shove (the surfer stops like at a wall), a stack of blocks.

**D5. Skim crossing.** *Settled water pool + a surf run-up.* The pool is a road if you arrive at 180+. If you drop below, you swim (and you'd end up in an electrified or slag pool if it changes). *Twists:* crust over the far half makes it a plain floor; an arc/spark strikes while you're crossing; the basin's rim is a natural ramp out.

**D6. Steam launch.** *Steam column (crust formation, a boiled basin) + surf.* The board rises through the column (up to 120 px/s) to a ledge or an upper route. It only works while surfing, and ceilings stop it. A non-surfing player can't use it at all, so it is a surf-only shortcut. *Twists:* a second route for non-surfers that is longer; the column only exists while the laser boils.

**D7. Bowling lane.** *Grunts, tread crawlers and drillbots (from behind only) along a fast lane.* A chain pays 5/10/20 points within a 2 s window. Drillbots punish approaching from the drill side; mines stop the surf and arm; use a barrier to break the lane at a precise speed. *Twists:* a bowled-over grunt that is mid-windup is still bowled; a lane that bends so one enemy faces you.

**D8. Belt and brake.** *Conveyor running against the surfer + stall gate.* If belt speed ≈ the board's speed, the surf stalls. A powered belt lets a button *change what the run does*: belt off = easy, belt on = need more speed. A speed trap *reads* the surf plus belt ground speed.

### E. Traversal and spatial

**E1. Underside route.** *Catwalk (own layer) over spikes or slag.* The player hangs by crouch+jump from standing on the catwalk (or jumps up into it), brachiates across, and mantles at the end. A ladder cell in the path hands off to a climb. *Twists:* the catwalk ends and the player must swing/jump; terrain under the catwalk blocks brachiating; a crust underside as the continuation.

**E2. Hang from things that move.** *Doors, blocks, see-saw ends, moving and drop platforms are all hangable.* A door that opens releases a hanger (a shaft with a door the player is hanging from), a drop platform releases at its drop, a floating block bobs. These are timed vertical routes. *Twists:* a block that melts under the player; the see-saw end is only hangable within 15° and slowly.

**E3. Rail ride.** *Steep and flat rail segments + rail bot.* Slide down the steep part (speed builds), brachiate along the flat part (friction brings you to a stop), and jump past a bot (contact hurts, and knocks you off). Catching a slope keeps a share of your speed. Jumping off carries the slide's velocity. *Twists:* the rail passes over a pool or slag; sparks drip down on the route below; a laser kills the bot (the usual solution) or a mine blast does.

**E4. Crouch gap + sneak.** *Low corridor* that only a crouched player fits, a long one needs sneak at 50 px/s while a Grunt or timing cycle pushes pressure. Standing back up is blocked by a real overlap check under a ceiling, so you creep out. *Twists:* crouching while a crusher cycles; a button *inside* the corridor requires a crouch-press (the crouch itself is the click).

**E5. Ladders and landings.** A ladder through a catwalk is a clean route up; you can brachiate onto it from beneath. *Twists:* a spike tile in a ladder cell breaks climbing (don't do that); a ladder that ends at a door.

**E6. Pad chains.** *Jump pads aimed by rotation + a moving platform or swing as the landing.* Pads keep the surf's speed. Powered pads are *live only when a source says so*, so a pad route can be a timed window. Blocks also get launched (lighter ones go higher).

### F. Timing, rhythm and traps

**F1. Phase corridor.** *Crushers, sawwheels or cannons with `phase_offset`.* The spike is the dangerous end and the arm (side) is solid; dwell windows are the safe beats. Stagger so the player has to learn a rhythm. *Twists:* a powered crusher parks *safe* when off, so a button is a pause; a TIMED button pauses it just long enough.

**F2. Jam it.** *Crusher + metal block.* Kick metal under the extending spike; the crusher jams, parks and stays harmless. The corridor is permanently safe, but the block is stuck there (and wired crushers reset on a power cycle, which makes a trap-reset you can trigger by accident). *Twists:* **ice is the wrong tool** (it shatters into water, which might be wanted: water onto slag crusts it); the metal must first be melted off a laser line, then moved.

**F3. Shatter delivery.** *Crusher above a basin + ice block.* An ice block shattered by the crusher bursts into water **at the crusher**. Water onto slag below crusts it. A way to *deliver water on a timer*. **(untested)**

**F4. Bullet counter.** *Cannon + mirror with `bullet_rotates` + bullet targets.* Each bullet turns the mirror a step and is consumed. The bullet target gets hit only when the mirror aims right. A cannon firing every second advances it without the player. *Twists:* the player kicks it too (race); a TOGGLE bullet target latches the result.

**F5. Cannon pulse trains.** *Cannon + MOMENTARY bullet target.* Fire rate shorter than `pulse_length` keeps it powered; longer lets it flicker. Choose the cannon's rate to decide whether a door is steady or blinks.

**F6. Telegraph reading.** *Arc turret and rail bot glows (0.45 s), grunt windup (amber).* Teaching language: amber = coming, red = live. Use it consistently.

### G. Enemies as mechanisms

**G1. Boot the mine.** *Mine + grunts.* Kick a mine into a grunt group (a mine that slides faster than 40 into a wall or any enemy detonates; a blast hits everything in 40 px and chains to other mines). *Twists:* a laser arms a mine from far away (arm, never damage); a rail bot overhead killed by a mine blast; mines on both sides of a door.

**G2. Crawler stepping stones.** *Tread crawler between two safe spots over spikes or slag.* Stomp it flipped (you bounce), then stand on it. It stays pinned while you stand there. After the top is clear it rights itself after 4 s. *Twists:* one stone, two players of time; the crawler flips on the far side of a pit because its patrol ends there.

**G3. Lure.** *Grunt + laser.* A chasing grunt stops at a ledge and walks into a beam; the laser does 1 damage per 0.5 s, so two beams or a long exposure kill it. *Twists:* an enemy in the beam *shields* a receiver behind it (a Stingbot crossing it flickers it); a grunt chased onto a plate does nothing (enemies weigh nothing).

**G4. Stingbot windows.** *Stingbot landing for 2 s every 8 s.* The recharge is a safe window. Use it as a timed door-opening or a way to cross a hazard *under* its flight path. It doesn't avoid obstacles, so a wall can *trap* it. **(untested)**

**G5. Drillbot lane.** *Drillbot patrolling a narrow ledge.* Bowl it from behind (surf), or kick it three times *from behind* (its body is harmless), or cross over the top. *Twists:* the free-patrol (`patrol_distance` 0) walks to ledges, so it patrols the whole platform.

### H. Information, routing and pacing

**H1. Gem trail on a switch.** *Powered gems + a source.* The gems of a trail appear only while powered. A timed source shows the route briefly; a latched one shows it permanently. Trails double as **route hints** for launch arcs. Powered gems are free to place in quantity. *Note:* use 5 or 10 point values (popups exist for 5, 10, 20, 50).

**H2. Bonus route.** *Bonus gems (50 pts, not part of the unlock %)* guard risky detours. Pair with a medkit at the end of the risky path.

**H3. Locked finish.** *Finish with `require_all`* gems + a button, or OR for two routes. A level where 100% gems are impossible without the button, and a level where the button is *optional*, change the pacing.

**H4. Checkpoint-aware design.** *Place checkpoints before expensive resets.* Blocks, doors, basins (fill and crust) and enemies are restored; liquid particles, arcs, bullets and sparks aren't, so avoid designs where success depends on an in-flight particle. A restore always sets dangerous things harmless (mines dormant, grunts recovering, drips restarted).

### I. Full-room recipes (stacks of the above)

**I1. The Foundry.** Metal block on a ledge, laser aimed at it (A3). Block melts and slag pours into a basin (B2). Water from a faucet (button) crusts it, making a bridge and steam. The player crosses the crust, and the steam carries a surfer to the upper ledge (D6) with a speed trap on the final line. Checkpoint before the pour.

**I2. The Clockwork.** Motorized see-saw (C6) with an angle sensor (clock), a crusher (F1) and a mirror that advances on each sensor rising edge (A2). The receiver on the exit lights only at one step, so the player has to *wait for the right beat and be at the door*. A second receiver needs the player to jam the crusher with a metal block (F2).

**I3. The Reservoir.** A basin chain: faucet → basin 1 (spill) → basin 2. An ice block floats up in basin 1 (B1) to reach a laser, which melts it and the water spills to basin 2 (a basin sensor opens a door at 50%). A rail bot sparks basin 2 on a timer (B8), so the swim to the door is timed.

**I4. The Gauntlet.** A surf run: downhill, a wet section (B7) to hit 800, a barrier at `break_speed` 700 (D3), a speed trap (D2) whose door is 12 tiles on, a launch to a swing (C4), and a release onto a crust bridge. Gems along the arc as guides. Grunts in the lane for a chain.

**I5. The Lock Box.** Three receivers in AND (laser, arc, bullet target) around one vault door. Laser via a mirror relay (A1), the arc via ricochet (A6) and the cannon bullet via a counter mirror (F4). Each is solvable on its own and then interacts: the arc and the laser share a mirror, so turning it for one breaks the other.

Reads with: `level-design.md` (every object, surface and interaction the patterns use, and the gaps), `roadmap.md` (planned mechanics that will add primitives), `power.md` (the logic contract behind the logic primitives), `lasers-arcs-mirrors.md`, `liquid-system.md`, `player-surf.md`, `rotating-bodies.md`, `meltable-blocks.md`, `enemies.md`
