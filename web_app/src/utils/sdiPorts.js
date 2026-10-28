// DeckLink SDI port maps.
//
// DeckLink Duo 2: the Blackmagic driver enumerates the card's four physical connectors out of
// order, so the `device_number` stored on a destination has to be translated to a connector label:
//   io0 -> SDI 1, io1 -> SDI 3, io2 -> SDI 2, io3 -> SDI 4
// Verified against the lab card: the kernel log reports io0 = "DeckLink Duo 2 (1)", io1 = "(3)",
// io2 = "(2)", io3 = "(4)". (Taken from the feat/decklink-duo2 branch, where this mapping was
// established against the hardware; the Quad 2 eight-port map that used to live here did not match
// this card at all.)
export const DEVICE_TO_SDI = { 0: 1, 1: 3, 2: 2, 3: 4 };
export const SDI_TO_DEVICE = { 1: 0, 2: 2, 3: 1, 4: 3 };

export const SDI_PORT_OPTIONS = [
  { label: 'SDI 1', value: 0 },
  { label: 'SDI 2', value: 2 },
  { label: 'SDI 3', value: 1 },
  { label: 'SDI 4', value: 3 },
];

// A save on a RUNNING route restarts it, and that restart can be refused by the server because a
// listening port or an SDI connector is already taken. The refusal arrives as `restart_error` beside the
// saved record ("SDI 1 is in use by <route>"), which is the same sentence the Start button shows. One
// copy of the pattern, so RouteItem's conflict toast and the edit forms cannot drift apart.
export const RESTART_CONFLICT_RE = /(SDI \d+|port \d+) is in use by/;

// The card's duplex profile is not configurable here: the engine pins every SDI sink to
// `two-sub-devices-half`, which is what makes all four connectors usable as outputs. A profile the
// card cannot run fails its SDI sink, so there is nothing for an operator to choose.
