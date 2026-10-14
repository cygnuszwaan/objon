# Level plan

A proposed campaign of 95 levels in 11 chapters. Each chapter introduces a small set of new objects or mechanics, uses the concepts in `puzzles.md` as its set pieces, opens with a step down in difficulty while the new material is taught, and ramps back up to a finale. Puzzle IDs (A1, B11, I12 and so on) refer to `docs/puzzles.md`, where each puzzle is described in full with its twists and its **(untested)** marks; this document only says where each one goes and which twists to use. IDs there are positional, so if concepts are merged or renumbered in `puzzles.md`, update the IDs here. A level may hold several small puzzles or a single brainteaser; the **set pieces** are the bullets under each level. 111 of the 119 concepts are used; the rest are listed as spare parts at the bottom.

Covers: Principles; Difficulty scale; Chapter overview; Chapters 1 to 11 (1 Footing; 2 Momentum; 3 Light; 4 Weight; 5 Blocks; 6 Rhythm; 7 Enemies; 8 Water; 9 Steam; 10 Memory; 11 Grand works); Spare parts

## Principles

- **Teach, test, twist.** A new object first appears where nothing can go wrong (no hazard, no timer), is tested in the next level with a catch, and gets its twist after that. The opener of each chapter is the "teach" level.
- **Step down, then ramp.** Every chapter opens 2 to 4 points below the previous chapter's peak, builds with one new idea per level, places a full-room recipe (the I entries) mid-chapter or as the finale, and ends at its peak. A level that introduces a new object may dip by a point inside a chapter; that is deliberate.
- **Callbacks are free difficulty.** Later chapters reuse earlier objects in new combinations (a surf level inside the water chapter, a mirror inside the weight chapter), so the player's old skills keep paying.
- **H4 Checkpoint-aware design applies everywhere.** Checkpoints go on ground before any expensive reset, never mid-bridge or mid-steam. Levels list a checkpoint note only where it changes the design.
- **F6 Telegraph reading is one language from chapter 1.** Amber is coming, red is live, a blink is leaving. Never use a spike layer where a visible telegraph (a bullet in flight, a camera cue, a blink) is available.
- **Every level can carry a bonus route** (H2) and a gem trail (H1); neither is listed per level unless it is the point of the level.

## Difficulty scale

| | Meaning |
|---|---|
| 1 | Verb practice; failing costs a few seconds |
| 2 | One idea, one obvious solution |
| 3 | One idea with a small catch |
| 4 | One idea, needs a plan or a clean execution |
| 5 | Two ideas combined |
| 6 | Planning plus precision; a wrong first move costs a retry |
| 7 | Multi-stage; the stages interact |
| 8 | Hard; needs the whole chapter's vocabulary |
| 9 | Brainteaser or execution-heavy; several systems at once |
| 10 | Final exam of the campaign |

## Chapter overview

| Ch | Name | Levels | New objects and mechanics | Opens | Peaks |
|---|---|---|---|---|---|
| 1 | Footing | 8 | Crouch, sneak, ladders, catwalks and the underside hang, buttons, doors, TIMED and TOGGLE buttons, powered spike/catwalk/ladder layers, moving and drop platforms, jump pads, zone sensor, camera cue, rails | 1 | 5 |
| 2 | Momentum | 6 | Surf, breakable barriers, speed trap, conveyor belt | 2 | 6 |
| 3 | Light | 7 | Laser turret and receiver, glass, mirrors (kick, toggle, step), arc turret and receiver, freeze turret and receiver | 2 | 6 |
| 4 | Weight | 7 | Weight plate, ice and metal blocks, see-saw, angle sensor, swing, zone that counts blocks | 3 | 6 |
| 5 | Blocks | 9 | Block dispenser, carbon fiber and pushing, launching see-saw, blocks as shields | 4 | 7 |
| 6 | Rhythm | 8 | Crusher, sawwheel, cannon, bullet target, bullet-rotated mirror, motorized see-saw | 3 | 7 |
| 7 | Enemies | 9 | Grunt, mine, tread crawler, stingbot, drillbot, enemy-count zone, enemy weight on plates and planks | 4 | 8 |
| 8 | Water | 10 | Faucet, basin, water, slag, crust, drain, electrified water, freezable basin, liquid as load | 4 | 8 |
| 9 | Steam | 10 | Boiling laser, steam lift, steam on see-saws, thermal oscillator, fuel gauge | 5 | 9 |
| 10 | Memory | 10 | Delay, Latch, Counter and Pulse nodes, keys and hubs | 5 | 9 |
| 11 | Grand works | 11 | Nothing new: recipes, callbacks and the hardest brainteasers | 6 | 10 |

## Chapter 1: Footing

Teaches the player's own verbs and the language of powered terrain (a layer that appears, blinks and goes). No enemies and no lasers; the only hazards are spikes and falls. Opens at 1.

**1-1 First Steps** · difficulty 1 · *new: walk, jump, mantle, gems, medkit, checkpoint, finish*
- **H2 Bonus route**: bonus gems (50 points, outside the unlock percentage) guard a risky detour, with a medkit at its end. There is almost no puzzle; the detour is the lesson that risk pays.

**1-2 Mind Your Head** · difficulty 1 · *new: crouch, sneak, spikes*
- **E4 Crouch gap + sneak**: a low corridor only a crouched player fits; a long one needs sneak (50 px/s). Twists: standing up is blocked under a ceiling; a button inside the corridor is pressed by the crouch itself.

**1-3 Up and Under** · difficulty 2 · *new: ladders, catwalks, underside hang*
- **E5 Ladders and landings**: a ladder through a catwalk is a clean route up, and the player can brachiate onto it from below. Twist: a ladder that ends at a door.
- **E1 Underside route**: hang under a catwalk over spikes, brachiate across, mantle at the end. Twists: the catwalk ends and the player must jump; terrain under the catwalk blocks brachiating.

**1-4 Press and Cross** · difficulty 3 · *new: buttons, doors, TIMED button, powered spike/catwalk/ladder layers, ghost*
- **E8 Summoned route**: a TIMED button extends a bridge or ladder that blinks before it retracts. Start with the safe window (an inverted spike field), then a bridge, then a ladder race. Twist: a second TIMED button midway restarts the countdown.
- **H6 The telegraph ladder**: the ghost says where the route will be, the blink says it is leaving. Ghost on for the layer needed later, off for the one needed now.

**1-5 Moving Parts** · difficulty 3 · *new: moving platform, drop platform*
- **E2 Hang from things that move**: doors, blocks, moving and drop platforms are all hangable; a door that opens or a platform that drops releases the hanger. Twist: a door that opens releases a hanger in a shaft.

**1-6 Springs** · difficulty 4 · *new: jump pads*
- **E6 Pad chains**: jump pads aimed by rotation chain into a moving platform landing; powered pads are live only when a source says so, so a pad route can be a timed window.
- **H1 Gem trail on a switch**: powered gems mark the launch arc; a timed source shows the route briefly, a latched one permanently.

**1-7 Look Ahead** · difficulty 4 · *new: zone sensor, camera cue*
- **E7 Shut-in**: a zone covers a room and an inverted door at its entry closes behind the player; the exit is gated by the room's own puzzle. Twist: a `hold_time` of several seconds as a lock-out timer.
- **H5 Cue the opening**: a camera cue and an inverted spike layer on one source pan to the new route, so it needs no hint sign. Twists: `once`; the look-ahead trigger (a zone in place of the button).

**1-8 Stone and Steel** · difficulty 5 · *new: TOGGLE button, rails*
- **E10 Flip-flop stepping stones**: two catwalk layers on one source, one inverted, so for a moment both sets exist and the player can hop across. Twists: a static stone midway to wait on; `warn_time` 0 for a hard swap.
- **E3 Rail ride**: slide down a steep rail, brachiate the flat part, jump past a bot. Twists: the rail runs over spikes; sparks drip on the route below.
- **H3 Locked finish**: the finish needs every gem *and* a button, so 100% gems is impossible without the button.

## Chapter 2: Momentum

Introduces the surf, the signature verb, as a pure speed puzzle before any other system touches it. Opens at 2.

**2-1 Board** · difficulty 2 · *new: surf, breakable barrier*
- **D1 Banked speed**: downhill into a flat run to a barrier that needs 450 or more; only one line reaches that speed. Gems mark the line.

**2-2 Break Points** · difficulty 3
- **D3 Barrier gauntlet**: barriers with different `break_speed`s along a run, mixed `break_from` sides, so the player must still be fast after paying friction. Twist: the run continues into a launch.

**2-3 Door on the Clock** · difficulty 4 · *new: speed trap*
- **D2 Speed trap door**: the trap reads the surfer's speed as they cross its line and holds a far door for `hold_time`, so the player surfs and then runs. Twists: `require_surfing`; two traps in AND with different thresholds.

**2-4 Against the Belt** · difficulty 4 · *new: conveyor belt*
- **D8 Belt and brake**: a belt running against the surfer stalls the board near its own speed; a powered belt on a button changes what the run does. The speed trap reads surf plus belt.

**2-5 Speed Gate** · difficulty 5
- **D2 Speed trap door** (speed-gate twist): an inverted spike layer across the run instead of a door; below 450 the spikes stay out and knock the surfer off the board.
- **D1 Banked speed** (belt twist): a belt on the line as a speed tax or assist.

**2-6 The Long Run** · difficulty 6
- Callbacks only, nothing new: D1, D3, D2 and D8 in one run ending on a launch. It checks that the verb has been learned before the surf goes into other systems.

## Chapter 3: Light

Lasers, mirrors and receivers, from "the beam reaches the door" to multi-state optical logic, plus the arc and the freeze beam as variations on the same idea. Opens at 2.

**3-1 First Light** · difficulty 2 · *new: laser turret, laser receiver, glass*
- **A7 Shoot-through-a-wall**: a glass wall shows a receiver the player cannot reach; the beam is visible and the puzzle is getting a line of fire through.

**3-2 Bounce** · difficulty 3 · *new: mirrors*
- **A1 Mirror relay**: kick mirrors in 45° steps until the beam reaches the receiver. Twists: a mirror on a moving platform sweeps the beam (the receiver needs `hold_time`); `kick_rotates` off on switch-owned mirrors.

**3-3 Switchboard** · difficulty 4 · *new: toggle-mode mirror*
- **A8 Beam switch**: a toggle-mode mirror and a TOGGLE button choose which of two receivers (and doors) the beam feeds. Twists: each receiver's `hold_time` leaves a beat to run; `invert` swaps which state is A.

**3-4 Click Count** · difficulty 5 · *new: step-mode mirror, momentary button crouch-cycle*
- **A2 Combination lock**: each click (a crouch on a momentary pad) advances a step-mode mirror, and the receiver is lit only at the right step. Twists: two mirrors on two buttons in AND; a TOGGLE button teaches that only rising edges count.

**3-5 Slow Light** · difficulty 5 · *new: arc turret, arc receiver*
- **A6 Arc ricochet**: the arc is slow (220 px/s) and short (480 px), passes enemies and the player's layer, and bounces off mirrors. Twists: two arc receivers on TIMED latches in AND; a fizzled arc teaches range.

**3-6 Windows** · difficulty 6
- **A5 Window receiver**: a mirror on a moving platform lights the receiver only as it passes, so the gate must be reached in the window. Twists: a longer `hold_time` to forgive; two staggered platforms in AND.
- **A11 Optical gate**: two toggle mirrors in series and two buttons, so the beam reaches the receiver in only one state combination. Twists: a decoy receiver at each wrong endpoint wired to something that bites; `invert` on one wire.

**3-7 Cold Light** · difficulty 6 · *new: freeze turret, freeze receiver*
- **A13 Fire and ice**: a laser receiver and a freeze receiver on an AND door, both beams through one toggle mirror; the freeze dwell is a wait the laser must not interrupt. Twists: the freeze receiver's `hold_time` as the window to reach the door; the laser melts an ice block used as a cold shield.

## Chapter 4: Weight

Weight as a signal: plates, planks and swings, and blocks as loads. Mirrors and lasers come back as familiar background. Opens at 3.

**4-1 On the Plate** · difficulty 3 · *new: weight plate, ice and metal blocks*
- **C2 Plate budgeting**: a plate with a threshold and blocks of different weights (player 2, ice 1×1 = 1, metal 1×1 = 4); the player finds the combination. Twists: a plate under melting ice releases on its own; two plates in AND.

**4-2 Hold It** · difficulty 4
- **A9 Hold the beam**: a momentary button holds a toggle mirror on target, and a block on the pad holds the button, since the player cannot stand on the pad and be at the door. Twist: ice under a second laser, so the mirror swinging back is a visible countdown.

**4-3 Seesaw** · difficulty 4 · *new: see-saw, angle sensor*
- **C1 Counterweight**: the player alone (2) cannot tip the plank, so a metal block (4 per tile) is positioned first and the player completes the load. Twists: the door holds only while the plank stays tipped, so something must be left on it; the block sits on the plank *and* the plate.

**4-4 Swing Time** · difficulty 5 · *new: swing*
- **C3 Pump the swing**: grab the bar and pump with left and right until the arc passes the sensor. Twists: the sensor is on the far side, so the player must release at the right moment; the arc crosses a spike pit.

**4-5 Headcount** · difficulty 5 · *new: zone that counts blocks*
- **C7 Headcount**: a zone (`count_blocks`, `min_count` 3) counts bodies, not weight, so a 1×1 ice and a 1×1 metal are worth the same. Twists: a laser melts one once placed, so it must be shielded or timed; `count_player` too.

**4-6 Mass and Momentum** · difficulty 6
- **C4 Momentum into the swing**: a surfer in the air grabs the bar and passes the whole surf speed into the swing, releasing to launch far past a jump. Twists: the ±80° limit pins a fast catch (use `free_rotation`); a gem trail marks the release point.

**4-7 Equal Weights** · difficulty 6
- **C14 Equal weights**: a see-saw with sensors on both ways opens the door only when level, so the player must find two *equal* loads that do not look equal (a 1×1 metal balances a 2×2 ice). Twists: ice under a laser loses weight as the plank watches.

## Chapter 5: Blocks

Blocks as tools: the dispenser, the permanent carbon fiber block, the thrown block and the block that shades a beam. Opens at 4.

**5-1 Spare Parts** · difficulty 4 · *new: block dispenser*
- **C9 Spare weight**: a metal dispenser above a weight plate (threshold 4) with a button out of reach of the plate; the player cannot carry a block, so they press, then walk to the plate. Twists: threshold 6, so the player stands on the plate and presses a button reachable from it; a laser melts the block after 3 s and the slag pours onto the plate.

**5-2 Carbon** · difficulty 4 · *new: carbon fiber block, pushing*
- **E12 Pushed step**: a carbon fiber block pushed against a wall is a step up to a ledge out of jump reach. Twists: two ledges at two heights and one block, so the order matters; a slippery floor makes the block coast past the foot of the ledge.

**5-3 Throw** · difficulty 5 · *new: launching see-saw*
- **C10 Catapult**: a see-saw with `launch_gain`; the player stands on the raised end, a block is dropped on the other, and the throw lands them on a ledge out of jump reach. Twists: standing at the tip throws furthest, near the pivot a short hop; a spike pit between the plank and the ledge.

**5-4 Stack** · difficulty 5
- **E11 Block stack**: a dispenser high above the floor (`max_alive` 3, `cooldown` 0.5) drops blocks that pile into a staircase to a ledge. Twist: a laser across the top melts the highest block, so the player builds around it.

**5-5 Shove** · difficulty 5
- **D4 Shove delivery**: a surf shove sends an ice block about 18 tiles on its own to a distant plate or into a mine cluster. Twists: metal moves much less per shove; a ledge dumps the block; carbon fiber is the long version (a plate at threshold 2 ignores it, a zone does not).

**5-6 Plug in the Line** · difficulty 6
- **E13 Plug in the line**: a lane for a pushed block with an ice block sitting in it and a laser that can melt it; the push waits behind the melt. Twists: a metal plug floods the lane with slag; the plug sits on a plate that holds a door, so clearing it shuts the door.

**5-7 Shade** · difficulty 6
- **A3 Block shield**: a block in a beam shades a receiver on an inverted door, and the block's lifespan is the window (ice about 2 s, metal about 3 s). Twists: a dispenser makes the window re-armable; a carbon fiber block makes it a standing shadow.
- **A4 Beam-and-block race**: a laser melts the block holding a plate down, so the field the plate holds open closes on a timer. Twists: a mirror to re-aim and buy time; two blocks on one plate, or a second plate in AND.

**5-8 The Mint** · difficulty 7
- **I11 The Mint**: a metal dispenser beside a button drops a block on a plate that opens the first door. In the second hall a laser keeps the exit shut through an inverted receiver, and the shield that opens it has to come from the same dispenser (`max_alive` 1), so making the shield takes back the plate's block: the player must be through the first door before spending it, and the shield's window is the run down the hall. A camera cue on the first door's source shows the second hall opening; the checkpoint is after the first door.

**5-9 The Trebuchet** · difficulty 7
- **C11 Heavy drops, light flies**: a metal hammer throws an ice block, which flies far, onto a plate or across a gap. Twists: the ice is also a load on the raised end and resists the tip; the player is thrown too if they stand on the raised end.
- **I12 The Trebuchet**: a metal dispenser over the low end of a launching plank and a button out of reach of the plank's own platform; the player stands on the raised end, the button drops the block and the throw lands them on a ledge, and an angle sensor holds the door open for as long as the block stays on the low end. Beyond it, an ice block sits on the raised end of a second plank and a laser across a pit has to melt it to open the exit; the first block is the hammer for the second plank, so the player carries it there and has to be through the first door before it shuts.

## Chapter 6: Rhythm

Traps with a rhythm, and the cannon as a precise, readable clock. Opens at 3.

**6-1 Read the Signs** · difficulty 3 · *new: crusher, sawwheel*
- **F6 Telegraph reading**: amber is coming, red is live (arc and rail bot glow 0.45 s, grunt windup); the teaching language for the rest of the game.
- **F1 Phase corridor**: crushers and sawwheels with `phase_offset`; the dwell windows are the safe beats. Twists: a powered crusher parks safe when off; a TIMED button pauses it.

**6-2 Jam It** · difficulty 4
- **F2 Jam it, or run it**: kick a metal block under the extending spike and the crusher jams and parks, so the corridor is safe but the block is gone; a carbon fiber block can instead be pushed through the dwell. Twists: ice shatters to water; the metal must first be melted off a laser line.

**6-3 Under Fire** · difficulty 4 · *new: cannon, bullets, bullet target*
- **F8 Cover**: bullets no longer pass through blocks, so a metal block takes the hit and a block kicked into the lane is cover. Twists: the cover block is the one that has to end up on the far plate, so it cannot be left behind; a bullet target hidden behind metal is a gate in the form of a block.

**6-4 Count the Shots** · difficulty 5
- **F4 Bullet counter**: each bullet turns a `bullet_rotates` mirror a step and is consumed; the target is hit only when the mirror aims right. Twists: the player kicks the mirror too (a race); a TOGGLE bullet target latches the result.

**6-5 Tripwire** · difficulty 6
- **F7 Tripwire cannon**: entering a zone starts the barrage; set the zone back from the guns so the bullet in flight is the telegraph. Twists: `hold_time` keeps it firing after the player leaves; `invert` for a shelter zone; `count_blocks` lets a block start it from a distance.

**6-6 Motor and Brake** · difficulty 6 · *new: motorized see-saw*
- **C6 Motor and brake**: a heavy enough rider on the high side holds the motor against the stop; an oscillating see-saw is a moving ramp or bridge to time, and its angle sensor is a clock.

**6-7 The Lock Box** · difficulty 7
- **I5 The Lock Box**: three receivers in AND around one vault door: a laser by mirror relay, an arc by ricochet and a cannon bullet by counter mirror; each is solvable alone, and the arc and laser share a mirror.

**6-8 The Clockwork** · difficulty 7
- **I2 The Clockwork**: a motorized see-saw's angle sensor is the clock for a crusher and for a mirror that advances on each rising edge; the exit receiver is lit at only one step, so the player waits for the right beat and is at the door. A second receiver and a jam are the alternative route.

## Chapter 7: Enemies

Enemies as mechanisms (keys, clocks, weights, stepping stones) rather than as fights. Opens at 4.

**7-1 Hello, Grunt** · difficulty 4 · *new: grunt, aggro, windup*
- **G3 Lure**: a chasing grunt stops at a ledge and walks into a beam (1 damage per 0.5 s). Twists: an enemy in the beam shields a receiver behind it; a grunt chased onto a plate presses it.

**7-2 Boom Room** · difficulty 5 · *new: proximity mine, tread crawler, enemy-count zone*
- **G1 Boot the mine**: kick a mine into a grunt group; a mine sliding faster than 40 into a wall or an enemy detonates, with a 40 px blast that chains. Twists: a laser arms a mine from far away; mines on both sides of a door.
- **G6 Clear the room**: a zone with `count_enemies` drives an inverted door that stays shut until the last enemy is dead. Twists: two arenas in AND; `min_count` 2 lets the player leave one alive.

**7-3 Stepping Stones** · difficulty 5
- **G2 Crawler stepping stones**: stomp a tread crawler flipped and stand on it over spikes or slag; it rights itself 4 s after the top is clear. Twist: the crawler flips on the far side of a pit because its patrol ends there.
- **G11 Barricade**: enemies cannot move a block, so a carbon fiber block pushed into a corridor shuts it. Twists: the grunt is on the plate side of the block; a laser cannot melt it, so only a bullet or crusher clears it.

**7-4 Dead Weight** · difficulty 6
- **G7 Park the lure**: a chasing grunt stops at a ledge, so it parks in a predictable place: in a zone as a key, or on a plate as weight. Twists: two grunts on two ledges in AND; the pinned-crawler plate (stand on a flipped crawler to hold the door).
- **C8 Ballast**: a see-saw with `enemy_weight_scale` 1 weighs a grunt as much as the player. Twists: the plank held level by a grunt against a metal block, so killing the grunt trips the sensor; a patrol over the pivot rocks the plank.

**7-5 Clocks** · difficulty 6
- **G8 Patrol clock**: a crawler or rail bot on a fixed patrol crosses a zone each lap, powering a gate for the pass plus `hold_time`. Twists: a mirror that steps per rising edge counts laps; a freeze beam slows the clock.
- **A12 Patient receiver**: a freeze receiver with a dwell that the patrol cuts each lap, so it opens only if a gap is longer than the dwell. Twists: a second beam from another side; the lens that brightens as frost builds shows the wait.

**7-6 Stinger** · difficulty 6 · *new: stingbot*
- **G4 Stingbot windows**: a stingbot lands for 2 s every 8 s, and the recharge is a safe window for a door or a crossing under its flight path. It does not avoid obstacles, so a wall can trap it.
- **A5 Window receiver** (stingbot twist): a stingbot crossing the beam flickers the receiver, so the flight is a clock the gate must be reached in.

**7-7 Lanes** · difficulty 6 · *new: drillbot*
- **G5 Drillbot lane**: a drillbot on a narrow ledge; bowl it from behind with the surf, kick it three times from behind, or cross over the top. Twist: a free patrol (`patrol_distance` 0) walks to ledges.
- **D7 Bowling lane**: grunts, crawlers and drillbots (from behind only) along a fast lane; a chain pays 5, 10, 20 points inside a 2 s window, and mines stop the surf. Twist: a lane that bends so one enemy faces the player.

**7-8 Heads Up** · difficulty 7
- **G9 Cut the span**: a bridge exists while its source is off; a grunt chases the player across, and the far momentary button cuts the span under it. Twists: two bridges and two grunts; the grunt is parked at the far end by a zone.
- **G12 Overhead pass**: a route above a grunt's `aggro_height` does not exist for it, so the patrol is a clock for the drop at the exit. Twists: two grunts with different `aggro_height`; a flipped crawler as a stone for the drop.

**7-9 The Kennel** · difficulty 8
- **I7 The Kennel**: a shut-in room whose entry door closes behind the player, with two grunts and a dormant mine; a second zone counts the enemies and drives an inverted exit door, so the mine is the player's tool and the room must be cleared. A camera cue shows the exit opening.

## Chapter 8: Water

Liquids from first principles: water, slag, crusts and their hazards. Surf and enemies come back as callbacks. Opens at 4.

**8-1 Splash** · difficulty 4 · *new: faucet, basin, water, swim, floating blocks*
- **B1 Float up**: fill a basin so an ice block floats up to a ledge. Twists: a basin sensor opens a door at 50% fill and a drain brings the level back; metal sinks, carbon fiber floats lower and never melts.

**8-2 Crust** · difficulty 4 · *new: slag, crust, steam*
- **B2 Crust bridge**: pour water on slag and it crusts into a walkable slab, with steam. Twists: the water comes from a melting ice block; the steam rises into a ceiling gap and stops.
- **F3 Shatter delivery**: a crusher above a basin shatters an ice block into water at the crusher, so water is delivered to the slag below on a timer.

**8-3 Skim** · difficulty 5
- **D5 Skim crossing**: a settled pool is a road to a surfer at 180 or more, and a swim below that. Twists: crust over the far half makes it plain floor; an arc strikes mid-crossing.

**8-4 Raft** · difficulty 5
- **B4 Slag raft**: a metal block floats on slag for about 8 s; kick it across and ride, a tight timeline. Twists: ice dropped on the slag crusts it instead; the raft carries a weight onto a plate; a flipped crawler is a free third option.

**8-5 Underneath** · difficulty 5 · *new: drain, crust underside hang*
- **B3 Under the crust**: crust the slag, drain the liquid beneath to open a void, then hang and brachiate under the crust across the hazard. Twists: the void exists only while the drain is open; a second basin chained after the first.

**8-6 Live Wire** · difficulty 6 · *new: electrified water*
- **B8 Safe water**: a rail bot's spark or an arc electrifies the pool for 1 s per strike, so the swim is possible only in the gaps, which the telegraph glow shows. Twists: a surf over it fails; the strike comes from a ricocheting arc far from the turret.

**8-7 Frost** · difficulty 6 · *new: freezable basin*
- **B10 Frost bridge**: hold a freeze beam on a freezable basin for its dwell and it becomes a slick walkable slab, with no steam; a laser thaws it. Twists: a pool already electrified keeps its time on the crust; two basins with different `freeze_time`. Slag version: frozen slag lasts only while the beam rests on it, so a block holds the button.

**8-8 Heavy Water** · difficulty 6
- **B6 Hydraulic scale**: liquid is load on a see-saw (water 1 per tile of volume, slag 3), so a pour tips the plank until the sensor trips. Twists: the plank has `mirror_surface` so the pour aims a beam; a laser melts an ice block on the plank so the load keeps changing.

**8-9 The Causeway** · difficulty 7
- **I8 The Causeway**: a slag lake crossed in three beats: a summoned bridge with its ghost on, a pair of flip-flop stones on a see-saw clock, and a landing ladder that a TIMED button and a CRUST sensor both hold out. The checkpoint is on ground before the first button.

**8-10 The Cold Store** · difficulty 8
- **I13 The Cold Store**: a pool between two ledges, a rail bot above it and a freeze turret on a toggle mirror; a button swings the beam onto the pool for its dwell and it becomes a slab, and the rail bot's sparks electrify the slab on their drip, so the player hops across between strikes and brakes on the far ledge. A freeze receiver beside the far door needs the same beam held on it from a second mirror, and a grunt patrolling the far ledge cuts that beam every lap, so the player lets it pass before the dwell. A laser behind a glass wall can thaw the slab, so the way back is the swim or the hop.

## Chapter 9: Steam

Heat as a machine: boiling, lifting and tipping, and the first clocks built from liquids. Surf, blocks and see-saws all come back. Opens at 5.

**9-1 Boil Off** · difficulty 5 · *new: boiling laser, steam*
- **B5 Evaporation**: a laser with `boils_water` drains a pool that blocks the way, and a basin sensor releases a door when it is empty. Twists: a faucet-refilled pool never empties unless the beam stays on; slag is never boiled.

**9-2 Updraft** · difficulty 5 · *new: steam lift*
- **B11 Steam elevator**: boil a pool under a carbon fiber block on a catwalk shelf and the steam column lifts it up a shaft to a ledge, on a TIMED button. Twists: the pool drains as it boils, so each ride costs water; a rider slows the lift, and two ground it.

**9-3 Gauge** · difficulty 6
- **H10 Fuel gauge**: a basin sensor (FILL) drives powered gems as a visible tank for a boil budget, so the player can see how many rides are left. Twists: a TIMED faucet refuels at the price of a trip; a second chained pool is a second tank.

**9-4 Lift Off** · difficulty 6
- **D6 Steam launch**: a steam column carries a surfer up to a ledge, only while surfing and only while the laser boils. Twists: a longer route for non-surfers or a block lift on the same column; a block that rose ahead shades the column.
- **B7 Wet run-up**: melt ice at the top of a slope and the water wets the floor, raising surf top speed from 600 to 800, which a barrier at `break_speed` 700 needs. Twists: the laser must be redirected to start the melt; the water must reach the floor before it dries.

**9-5 The Foundry** · difficulty 6
- **I1 The Foundry**: a laser melts a metal block on a ledge and the slag pours into a basin; water from a faucet crusts it into a bridge, and the steam carries a surfer to the upper ledge, where a speed trap guards the final line. The checkpoint is before the pour.

**9-6 Hot Seat** · difficulty 6 · *new: steam on a see-saw*
- **B13 Heat scale**: a boil under one end of a see-saw (`steam_torque_scale` 1 or more), on a TIMED button or a mirror aim, tips the plank and an angle sensor holds a door. Twists: the duration plus the heat lag is how long the door is held; the pool drains as it boils, so each use is a budget.

**9-7 Counterpoise** · difficulty 7
- **C12 Balance of heats**: two vents at equal lever arms, two lasers on separate sources and two angle sensors into one door, so the stronger heat wins. Twists: unequal lever arms make one vent count for more; a metal block on one end makes the door an AND.
- **C13 Set and reset**: a limited see-saw with `restoring_torque` 0 and a vent under each end, an SR latch in plain view where one boil sets it and the other resets it. Twists: each short boil adds to the angle (a visible counter); the player's weight or a parked grunt is the reset.

**9-8 Pulse of Steam** · difficulty 7
- **B9 Relaxation oscillator**: a basin, a steady faucet, a FILL sensor and a drain wired to the sensor make a slow periodic signal; the thermal version is a laser, a boil pool, a see-saw and an angle sensor that drives the same laser inverted, so the loop closes through the plank and the steam.

**9-9 The Heartbeat** · difficulty 8
- **I22 The Heartbeat**: the thermal oscillator is the room's clock, and a second angle sensor on the plank powers a catwalk layer over a pit, so the bridge extends with the beat and blinks as it goes. The pool burns water, so the beat dies when it is dry and a faucet on a button is the refill; a grunt lured onto the plank detunes the bridge.

**9-10 The Boiler Room** · difficulty 9
- **I16 The Boiler Room**: a boilable pool under each end of a limited see-saw with `restoring_torque` 0, each with its own laser and button; the left vent sets the plank and opens the vault, the right vent resets it. A carbon fiber block over the left vent is a valve that can be pushed only one way, onto the right vent, where it plugs the reset; a grunt on a fixed patrol is a load on the plank, and each second boil needs a refill.

## Chapter 10: Memory

Logic with memory: the Delay, Latch, Counter and Pulse nodes, and the level structures they make possible (hubs, keys, shortcuts). Opens at 5.

**10-1 Hold the Point** · difficulty 5 · *new: Delay node*
- **H8 Hold the point**: a Delay (`on_delay` 4) raises its output only if the input stays on the whole time, so the player must hold a position with something hostile nearby. Twists: the input is an angle sensor on a see-saw, so only a steady counterweight opens it; `off_delay` keeps the route open for a while after.

**10-2 In Order** · difficulty 5 · *new: Latch node*
- **H7 Ordered switches**: three momentary pads and Latches in a chain, each taking the one before as a source, plus a reset pad. Twists: a Counter on the decoy pads arms a trap after three strikes; a block left on a later pad is a second solution unless the pads are out of kick reach.

**10-3 Either/Or** · difficulty 6
- **H9 Exclusive choice**: two pads and two Latches, each in the other's `reset_sources`, so the first pad pressed locks the other route out. Twists: the reset pad is behind the chosen route; a Delay on each pad's input so a brushing kick does not commit.

**10-4 Tally** · difficulty 6 · *new: Counter node*
- **A2 Combination lock** (Counter version): a Counter (`count_to` N) behind the pad counts the clicks with no mirror, and a ladder of Counters with a powered gem each puts one more gem on screen per click. Twists: `auto_reset_time` shuts the door again; a decoy reset pad wipes the tally; a bullet target counts cannon shots.

**10-5 One Shot** · difficulty 6 · *new: Pulse node*
- **A5 Window receiver** (fixed-length event): a Pulse (`duration` 4) behind the receiver turns each crossing into a 4 s event, so the window is a number the designer picks. Twists: a Pulse shorter than a cannon's `fire_rate` gives one shot per step-on; `invert_input` fires as the player steps off; `all_required` gives an AND that yields an event, not a level.

**10-6 Shortcut** · difficulty 6
- **H12 Shortcut latch**: a Latch set at the far end opens a return door, so the hard stretch is crossed once and the next death is a short walk. Twists: a reset pad on the outbound route closes it again; the same Latch is also a key.

**10-7 Alarm** · difficulty 7
- **F7 Tripwire cannon** (alarm twist): a Latch behind the zone keeps the room hostile after the player leaves, until a reset pad; a Delay between zone and Latch is a grace period. Twists: `start_on` begins the level alarmed and the puzzle is finding the pad; two zones in OR on one Latch.

**10-8 Keys** · difficulty 7
- **H11 Keys are latches**: Latch nodes as keys, a hub door as the lock and a powered gem per Latch as the key ring. Twists: a key set by a room's failure (a bridge cut, a mine blast); two doors each needing a different pair of three keys; a Delay used as an OR junction.

**10-9 The Vault** · difficulty 8
- **I10 The Vault**: a shut-in room with an alarm: a zone just past the entry sets the alarm Latch through a Delay (`on_delay` 2), so a player who crosses the hall quickly never trips it, and a cannon fires down the hall while it is on. Inside, three momentary pads must be pressed in order and a decoy pad on the way has a Counter (`count_to` 3), three strikes that set the same alarm Latch. The last Latch opens the vault door through a camera cue, and one reset pad in an alcove clears the alarm, the chain and the Counter at once. Every logic node has a visible consequence (a gem per stage, the cannon, the door); the checkpoint is just before the entry.

**10-10 The Atrium** · difficulty 9
- **I19 The Atrium**: a hub with a door and three gems, and three side rooms that each set a Latch: a re-armable shield window, a crusted basin read by a CRUST sensor, and a grunt parked on a plate. The light and enemy rooms are an exclusive choice, and the door reads "water AND (light OR enemy)" through a Delay junction, so there are two solutions. The checkpoint is in the hub.

## Chapter 11: Grand works

Nothing new is taught. The first levels are callbacks that mix early chapters; the later ones are the hardest recipes and brainteasers, ending on the Contraption. Opens at 6.

**11-1 The Moat** · difficulty 6
- **I6 The Moat**: a spike field fills the floor between two ledges with a catwalk above it. The no-tool route is the underside hang, always safe and slow; the fast route retracts the field with an ice block on a plate under a laser, a melt-timed window, and powered gems wired to the same source appear only while the field is open, so the fast line is marked exactly when it is safe. A speed trap at the far end can make the run a surf instead; the checkpoint is before the plate.

**11-2 The Signal Tower** · difficulty 6
- **I9 The Signal Tower**: one laser and two toggle mirrors in series. The first mirror is driven by an angle sensor on a see-saw (weight from the player or a metal block tips it, tilting back swings it back); the second by a TOGGLE button across a gap, which the player can instead kick into place from the near ledge. Three endpoints: a receiver on the exit door, a receiver that summons a bridge to the bonus gems, and a decoy that drives a spike layer on the stairs. Only one pair of states opens the door, and where the beam lands tells the player which mirror is off.

**11-3 The Switchback** · difficulty 7
- **I23 The Switchback**: a tall zig-zag climb of three floors, each with a grunt on a patrol. The way up is the low road past it, the way down an overhead hang above its `aggro_height`. A plate at the top sets a Latch that opens a ladder straight down the building, and a reset pad halfway up closes it again; the checkpoint is on the top floor past the plate.

**11-4 The Gauntlet** · difficulty 7
- **I4 The Gauntlet**: one long surf run: downhill, a wet section to hit 800, a barrier at `break_speed` 700, a speed trap whose door is 12 tiles on, a launch to a swing, and a release onto a crust bridge. Gems along the arc are guides and grunts in the lane make a chain.

**11-5 Periscope** · difficulty 7
- **A14 Periscope plank**: a see-saw with `mirror_surface` turns weight into a beam angle, so block size and material are an analogue dial and the player tunes the load until the beam lands on the receiver. Twists: two receivers on two beams off the same plank, so only one angle lights both; the plank is also a ramp.

**11-6 The Weighing Room** · difficulty 8
- **I18 The Weighing Room**: two planks. The first is a balance with a Latch behind its sensors, so matching a 1×1 metal against a 2×2 ice block opens the first door and powers a laser and frees the blocks; the second plank is a periscope that needs a narrow angle to reach a far receiver, tuned with the same blocks, carbon fiber and the player. A dispenser of carbon fiber is the trim weight and the checkpoint is after the first Latch.

**11-7 Hammer Time** · difficulty 8
- **C10 Catapult** (every hammer): one launching plank, three ways to fire it: a lured grunt (it weighs 2 against the player's 2, so something heavier must tip it), a motor with `launch_when_motorised` that throws whoever is on the raised end each cycle, and steam lifting the standing end with the laser as the hammer. Twists: an ice block on the lifted end is thrown further than the player; two ledges ask for two standing spots.

**11-8 The Assembly Line** · difficulty 8
- **E14 Block line**: a powered conveyor carries a block at a fixed speed, so its time anywhere on the belt is length over speed. Uses: a melt line under a beam, a dispenser spawning onto the belt so each block clears the footprint, and delivery to a plate over a pit. A belt cannot be reversed, so it is a one-way push built from a machine.
- **I21 The Assembly Line**: a metal dispenser at the head of a belt (`max_alive` 3) streams blocks toward a plate (threshold 8, so two pay); a laser across the belt is more than metal survives, so a carbon fiber block must first be pushed onto a shelf in the beam, and a crusher over the last stretch means each block is timed to its dwell while the belt's power sits on a TIMED button.

**11-9 The Porter** · difficulty 9
- **I14 The Porter**: a permanent carbon fiber block carried through a room one stage at a time. A dispenser and its button at the start; a lane with an ice plug that a laser melts, so the block waits behind the melt; a crusher corridor whose window the push must catch; a slag trench where the block is kicked onto a shelf while the player takes a catwalk hang over the same slag; a plate completed by the player's weight beside a zone that counts the block, with the door on their AND; and a cannon lane where a metal cover block must be kicked forward first. The checkpoint goes after the crusher.

**11-10 The Tide** · difficulty 9
- **B14 Rising slag**: a slag faucet used as a source pours in at the foot of a tall basin and the slag rises at `flow_rate` over the basin's width, a visible clock; it is stopped by the faucet's own power, a drain, or a crust. The docs do not say where inflow from below goes once a crust is over it, so test a crust over a live source first.
- **I20 The Tide**: a trip zone at the foot sets a Latch that opens the slag faucet, so the way back is closed; the player climbs ahead of the slag via a ladder layer on a TIMED button (restarted halfway by a second button), with a water faucet on a button as an emergency crust. A plate at the top closes the faucet and the checkpoint is just above it.

**11-11 The Contraption** · difficulty 10
- **I17 The Contraption**: a machine the player completes rather than operates. A button on a Pulse sends one cannon shot at a bullet-rotated mirror, which swings a laser onto a receiver; the receiver powers a boil turret under a carbon fiber block that rides the column up to a plate and opens the exit. Each link has one thing wrong (a metal block shading the receiver, a carbon fiber block on the wrong side of the vent, a summoned catwalk to the button) so the order is repair, return, press, and a camera cue per link shows the chain running.

## Spare parts

These concepts are not used above. Each is a ready alternative or extra for the slot named; their full descriptions are in `puzzles.md`.

- **A10 Scanner**: a toggle-mode mirror with a long `rotate_time` sweeps the beam over a receiver sitting between its two aims, so the player has to be at the door as it passes. Slot: a second set piece in 3-4, or a replacement for the mirror in 10-5.
- **B12 Width gate**: carbon fiber blocks of different widths (1×1, 2×1, 4×1) in a narrow boil column, where only the right width reads full lift and passes a gate or shaft. Slot: a second piece in 9-2 or 9-3.
- **C5 Plank-as-ramp**: a see-saw on a surf route is a ramp from the low end and a lip that stops the board from the raised end, so the player must arrive on the right side or level the plank. Slot: 4-6 beside C4, or a level between 4-6 and 4-7.
- **E9 Trapdoor**: an inverted catwalk layer retracts when a button is pressed and drops whatever stands on it (a block into a basin, or the player). Slot: a second piece in 1-5, or a late twist in 10-3.
- **F5 Cannon pulse trains**: a cannon feeding a MOMENTARY bullet target, where a fire rate shorter than the pulse keeps the target on and a longer one makes it flicker; with a spike layer it becomes a pulse floor. Slot: a second piece in 6-4, or a lead-in to 10-5.
- **G10 Short fuse**: a dormant mine on a weight plate holds an inverted spike layer open for as long as the mine lives, so the route has a timer that detonates. Slot: a second piece in 7-8.
- **I3 The Reservoir**: a basin chain where a floated ice block reaches a laser and its melt spills into a second basin that opens a door, with a rail bot sparking that basin so the swim is timed. Slot: an alternative to 8-9, or a mid-chapter level in chapter 8.
- **I15 The Dumbwaiter**: a carbon fiber dispenser at the foot of a shaft with its spawn over a catwalk shelf above a boil pool; a TIMED button fires the boil and the block rises to a deck above (the player does not ride it), where a plate, a zone and a metal cover block in a cannon's lane finish the job, with a fuel gauge of powered gems on the pool. Slot: an alternative to 9-9, or an extra level in chapter 11.

Reads with: `puzzles.md` (every concept the plan refers to by ID, with its twists and untested marks), `level-design.md` (the objects, surfaces and verbs the chapters introduce), `objon.md` (the core: the docs index and the rules for keeping the docs honest)
