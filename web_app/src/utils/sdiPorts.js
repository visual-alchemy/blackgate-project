// DeckLink SDI port maps.
// DeckLink Duo 2: 4 SDI connectors. Hardware sub-device order is NOT linear:
// kernel enumerates io0="(1)", io1="(3)", io2="(2)", io3="(4)".
// Map device_number -> physical SDI connector accordingly.
export const DEVICE_TO_SDI = { 0: 1, 1: 3, 2: 2, 3: 4 };
export const SDI_TO_DEVICE = { 1: 0, 2: 2, 3: 1, 4: 3 };

export const SDI_PORT_OPTIONS = [
  { label: 'SDI 1', value: 0 },
  { label: 'SDI 2', value: 2 },
  { label: 'SDI 3', value: 1 },
  { label: 'SDI 4', value: 3 },
];
