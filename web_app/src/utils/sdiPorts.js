// DeckLink Quad 2 SDI port map.
// Blackmagic driver enumerates physical connectors out of order:
// io0→SDI 1, io1→SDI 3, io2→SDI 5, io3→SDI 7,
// io4→SDI 2, io5→SDI 4, io6→SDI 6, io7→SDI 8.
// Map backend device_number -> physical SDI connector accordingly.
export const DEVICE_TO_SDI = { 0: 1, 1: 3, 2: 5, 3: 7, 4: 2, 5: 4, 6: 6, 7: 8 };
export const SDI_TO_DEVICE = { 1: 0, 2: 4, 3: 1, 4: 5, 5: 2, 6: 6, 7: 3, 8: 7 };

export const SDI_PORT_OPTIONS = [
  { label: 'SDI 1', value: 0 },
  { label: 'SDI 2', value: 4 },
  { label: 'SDI 3', value: 1 },
  { label: 'SDI 4', value: 5 },
  { label: 'SDI 5', value: 2 },
  { label: 'SDI 6', value: 6 },
  { label: 'SDI 7', value: 3 },
  { label: 'SDI 8', value: 7 },
];
