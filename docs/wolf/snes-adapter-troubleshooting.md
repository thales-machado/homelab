# SNES controller adapter (MayFlash MF105) troubleshooting

Two real problems with the USB adapter that carries the original SNES controllers into Wolf, with the fix for each. They look like the same bug but have different causes, one per Moonlight client. For the adapter's modes, button mapping and d-pad swap, see `mayflash/mf105-reference.md`.

## Only 1 of the 2 controllers works (Moonlight on Windows)

Symptom: `joy.cpl` (Windows' own DirectInput/XInput panel) and the SDL2 Gamepad Tool both see the two controllers fine (d-pad and buttons tested on each), but in game through Moonlight only Player 1 responds, and `docker logs wolf` only ever shows `Creating Xbox joypad for controller 0`, never `controller 1`.

**Root cause**: Moonlight-qt on Windows uses its own SDL mapping database, independent of `joy.cpl` and the SDL2 Gamepad Tool: `%LOCALAPPDATA%\Moonlight Game Streaming Project\Moonlight\cache\gamecontrollerdb.txt`. The adapter reports a different USB PID per physical port (`0x2f24:0x00f1` on one, `0x2f24:0x00f5` on the other, confirmed in `%TEMP%\Moonlight-<timestamp>.log` by looking for `Unmapped joystick` and `Gamepad N (player N) is:`). That database only had a mapping for PID `f5`, so PID `f1` stayed unmapped (`SDL_IsGameController() == false`), Moonlight never promoted that joystick to a gamepad and sent none of its input to Wolf. `joy.cpl` and the SDL2 Gamepad Tool are unaffected because they use their own mapping.

**Fix**: add the missing GUID to Moonlight's `gamecontrollerdb.txt`, reusing the button mapping of the port that already works (same physical hardware, only a different PID per port). Confirmed in production: adding both lines made both controllers work.

```
03000000242f0000f100000000000000,Mayflash N64 Adapter,a:b2,b:b1,x:b3,y:b0,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,leftshoulder:b4,lefttrigger:b6,leftx:a0,lefty:a1,rightshoulder:b5,rightx:a2,righty:a5,start:b9,platform:Windows,
03000000242f0000f500000000000000,Mayflash N64 Adapter,a:b2,b:b1,x:b3,y:b0,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,leftshoulder:b4,lefttrigger:b6,leftx:a0,lefty:a1,rightshoulder:b5,rightx:a2,righty:a5,start:b9,platform:Windows,
```

**Quirk**: SDL's original entry for that PID defines only `a`, `b`, `leftshoulder`, `rightshoulder`, `lefttrigger`, `start` and the d-pad, with no `x`, `y` or `back` (Select), because it was written for a real N64 controller, which has no X/Y face buttons. With only that entry, the d-pad and Start work while X, Y and Select are dead. The correct `x`, `y` and `back` bits for this adapter came from a custom mapping generated locally with the SDL2 Gamepad Tool, tested button by button, and merged into the lines above; they do not exist in the upstream SDL/Moonlight database.

Validated in a real two-player SNES game: d-pad, B/A/X/Y, L/R, Select and Start all working. Inside ES-DE, `leftshoulder` (L) launches the selected game and `rightshoulder` (R) opens the main menu, which is ES-DE's normal behavior, not a mapping bug.

If another adapter shows the same symptom (one of N controllers dead in Moonlight but fine in `joy.cpl`), suspect this incomplete mapping database before investigating hardware or drivers.

## The d-pad works but no other button does (Moonlight on Android / Google TV)

Symptom: Moonlight Android (`com.limelight`) sees the controllers and the d-pad works, but no face, shoulder, Start or Select button responds.

**Root cause, different from the Windows one**: on Android the HID-to-button mapping is not done by Moonlight (that app has no SDL), it is done by the **operating system**, through a key layout file per `vendor:product` (`dumpsys input` shows which file each device uses). With no file for this adapter, Android falls back to `/system/usr/keylayout/Generic.kl`, which assumes the old joystick button order (trigger/thumb/top) rather than the modern gamepad layout. The buttons therefore arrived in Moonlight as `KEYCODE_BUTTON_L2`, `R2` and `Z` instead of `A`, `B`, `X` and `Y` (confirmed with `adb logcat`, grepping `InputDispatcher` / `publishKeyEvent` and comparing the reported `keyCode` values against Android's `KeyEvent.KEYCODE_BUTTON_*` table).

The proper fix, dropping a `Vendor_2f24_Product_00f1.kl` into `/data/system/devices/keylayout/` (which takes precedence over `Generic.kl`), **needs root**, and the TV refuses (`adbd cannot run as root in production builds`), so that route is not viable without unlocking it.

**Fix without root**: switch the adapter to **PC XInput mode** (green LED) instead of DirectInput (blue LED). DirectInput reports through the old joystick codes, which matches the `Generic.kl` symptom; XInput exposes a standard gamepad usage page, which `Generic.kl` maps natively to the correct A/B/X/Y/L/R/Start/Select. Validated in production on a real two-player SNES game.

**Note**: this fix belongs to the client, not the adapter, and has nothing to do with the Windows `gamecontrollerdb.txt` fix above. Each Moonlight client has its own mapping layer, so if a third client shows a similar symptom, diagnose that layer from scratch instead of assuming it is the same bug.
