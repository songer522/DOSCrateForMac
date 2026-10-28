# Controller probe findings (2026-10-27)
## Xbox (wired USB), Staging 0.83.0 / SDL 2.32.10
- Log: "Game controller 'Controller'", 6 axes, 18 buttons, 0 hats.
- Map lines: key_<name> "stick_0 button N" "key <SDL scancode>"; bindings are raw joystick indices.
- A=b0, Menu=b3, d-pad up=b11 down=b8 left=b9 right=b10, LT=b14 (button, not axis), RT=b17.
- Left stick not probed yet.
- Mapper opens via --startmapper (Ctrl+F1 not reaching app); select key, click Add, press control.
- Vendor app ran from AppTranslocation (quarantine flag on Vendor/DOSBox Staging.app).
## DualSense, same Staging
- Log: "DualSense Wireless Controller", 6 axes, 17 buttons, 0 hats.
- Cross=b0, Options=b6, d-pad up/down/left/right=b11/12/13/14, L2="axis 4 1", R2="axis 5 1".
- Matches SDL GameController standard order. Axis format: "stick_0 axis N 0|1" (0 = negative, 1 = positive).
- Wired Xbox ("Controller", triggers as buttons) looks unrecognised by SDL; retest over Bluetooth.
## Steam Controller (2026 model, Steam not running)
- Detected by SDL without Steam: "Steam Controller", 6 axes, 25 buttons, 0 hats.
- A=b4, Start=b7, d-pad up/down/left/right=b14/11/12/13, LT=b17, RT=b24, left stick left="axis 0 0".
## Conclusion
- Staging binds raw joystick indices. Only DualSense matches SDL standard order; Xbox wired and Steam each differ, and their indices collide (b11 = up on Xbox/DualSense, down on Steam).
- So one static map cannot serve all three; the map must be chosen per controller model.
## Round 2: wireless (DualSense and Steam round-1 runs were wired)
### Xbox, Bluetooth
- "Xbox Series X Controller", 6 axes, 16 buttons. A=b0, Menu=b6, d-pad b11/12/13/14, LT="axis 4 1", RT="axis 5 1", stick left="axis 0 0".
- Standard SDL order (same as wired DualSense). Wired Xbox ("Controller", 18 buttons) is the odd one.
### DualSense, Bluetooth
- "DualSense Wireless Controller", 6 axes, 17 buttons. Identical to wired; standard order, stick left="axis 0 0".
### Steam Controller via puck (2.4 GHz dongle; Bluetooth not tried)
- "Steam Controller Puck", 6 axes, 25 buttons. Identical numbering to wired Steam Controller.
- hidutil: puck is VID 0x28de PID 0x1304, Transport USB, Product "Steam Controller Puck".
## Final layouts
- standard (SDL order): Xbox Bluetooth, DualSense wired + Bluetooth.
- steam: Steam Controller wired + puck. A=b4 Start=b7 d-pad up/down/left/right=b14/11/12/13 LT=b17 RT=b24 (digital) stick=axis 0/1.
- xbox-usb: wired Xbox ("Controller"). A=b0 Menu=b3 d-pad b11/8/9/10 LT=b14 RT=b17 (digital).
- Follow-up: Steam B=b5, X=b9, Y=b10 (A=b4).
- Follow-up: wired Xbox B=b1, X=b6, Y=b7, stick left="axis 0 0", stick UP="axis 1 1" (Y axis inverted vs SDL convention).
- Stick up not probed on standard or steam layouts (assumed "axis 1 0"); verify in the device test.
## Switch 2 Pro
- Wired: SDL 2.32.10 (Staging 0.83) finds no joystick; macOS HID lists "Pro Controller" VID 0x057e PID 0x2069 USB. Not supported natively on Mac (needs a third-party bridge, per owner). Out of scope.
- Wired Xbox HID (hidutil): VID 0x045e PID 0x0b12, Transport USB, usage 1/5, Product "Controller", UserClass XboxSeriesXGamepad.
