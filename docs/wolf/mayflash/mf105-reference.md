# MayFlash MF105: SNES controller adapter

Operating notes for the adapter that carries the original SNES controllers into Wolf, written down here because they are needed while mapping controllers. Not the manufacturer's manual: the full manual and the firmware updater are on MayFlash's own support and download pages (`www.mayflash.com`), and the device also works on a Nintendo Switch, which is out of scope here.

For the two real problems found in production, see `snes-adapter-troubleshooting.md`.

## Modes

The adapter takes up to 2 controllers (Player 1 and Player 2). Holding the **HOME** button cycles the mode, and the LED colour shows which one is active:

| LED | Mode |
|---|---|
| Red | Nintendo Switch |
| Green | PC XInput |
| Blue | PC DirectInput |

**XInput is the mode to use here.** DirectInput reports buttons through the old joystick codes, which is what breaks the face buttons on the Android/Google TV client (see the troubleshooting doc). The adapter's HOME button only acts for Player 1.

## Turbo, Auto Fire and Hold

`TURBO 1` configures Player 1 and `TURBO 2` Player 2, separately. Holding the TURBO button together with another button cycles that button through Turbo, Auto Fire, Hold and off; pressing the TURBO button twice quickly clears every setting for that player. The TURBO LED is solid when at least one button is configured, blinks fast while those buttons are in use, and is off when nothing is configured.

Neither Turbo nor Auto Fire is used in this setup: with Run-Ahead on the 2D cores, extra input repetition only makes behavior harder to reason about.

## Swapping the d-pad and the left stick

This matters for controller troubleshooting, because it changes what the physical d-pad reports:

- **START + A** held for 3 seconds makes the d-pad report as the left stick.
- **START + B** held for 3 seconds puts the d-pad back to normal.

The change is saved in the adapter, and setting it on Player 1 applies it to Player 2 as well. If the d-pad stops working as a d-pad after someone fiddled with the controller, check this before anything else.

## Button mapping

What the SNES buttons report in each mode, which is what the SDL and Android mappings in the troubleshooting doc are built against:

| Mode | B | A | Y | X | L | R | Select | Start |
|---|---|---|---|---|---|---|---|---|
| PC XInput | 2 | 3 | 4 | 5 | 6 | 7 | | 8 |
| PC DirectInput | 2 | 3 | 4 | 5 | 6 | 7 | | 8 |
| SNES controller | B | A | X | Y | L | R | SELECT | START |

The d-pad reports as a POV hat in both PC modes. The numbers come from a low-resolution figure, so treat them as a starting point and confirm with the SDL2 Gamepad Tool (Windows) or `adb logcat` (Android) when a mapping does not behave.
