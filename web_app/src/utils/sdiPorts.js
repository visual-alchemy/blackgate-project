// DeckLink Duo 2 SDI port map.
// Blackmagic driver enumerates the 4 physical connectors out of order:
// io0→SDI 1, io1→SDI 3, io2→SDI 2, io3→SDI 4.
// Map backend device_number -> physical SDI connector accordingly.
export const DEVICE_TO_SDI = { 0: 1, 1: 3, 2: 2, 3: 4 };
export const SDI_TO_DEVICE = { 1: 0, 2: 2, 3: 1, 4: 3 };

export const SDI_PORT_OPTIONS = [
  { label: 'SDI 1', value: 0 },
  { label: 'SDI 2', value: 2 },
  { label: 'SDI 3', value: 1 },
  { label: 'SDI 4', value: 3 },
];
