import {
  checkTransition,
  civilianStateOf,
  RESPONDER_STATES,
  type ResponderState,
  type ResponderTransition,
} from '../src/services/incidentStateMachine';

// Written out independently of RESPONDER_TRANSITIONS so a change to the
// table has to be made (and justified) in both places.
const VALID: Array<[ResponderState, ResponderTransition]> = [
  ['reported', 'acknowledged'],
  ['reported', 'assigned'],
  ['reported', 'stood_down'],
  ['acknowledged', 'assigned'],
  ['acknowledged', 'stood_down'],
  ['assigned', 'en_route'],
  ['assigned', 'assigned'], // reassignment to someone else
  ['assigned', 'stood_down'],
  ['en_route', 'arrived'],
  ['en_route', 'assigned'], // reassignment to someone else
  ['en_route', 'stood_down'],
  ['arrived', 'assisting'],
  ['arrived', 'resolved'],
  ['assisting', 'resolved'],
];
const TARGETS = RESPONDER_STATES.filter((s): s is ResponderTransition => s !== 'reported');
const isValid = (from: ResponderState, to: ResponderTransition) => VALID.some(([f, t]) => f === from && t === to);
const reassign = { current: 'responder-1', next: 'responder-2' };

describe('responder state machine', () => {
  it.each(VALID)('allows %s → %s', (from, to) => {
    expect(checkTransition(from, to, reassign)).toEqual({ ok: true });
  });

  const invalid = RESPONDER_STATES.flatMap((from) =>
    TARGETS.filter((to) => !isValid(from, to)).map((to) => [from, to] as [ResponderState, ResponderTransition]),
  );
  it.each(invalid)('rejects %s → %s', (from, to) => {
    const result = checkTransition(from, to, reassign);
    expect(result.ok).toBe(false);
  });

  it('covers every pair (valid + invalid = all states × all targets)', () => {
    expect(VALID.length + invalid.length).toBe(RESPONDER_STATES.length * TARGETS.length);
  });

  it.each([
    ['arrived', 'acknowledged'],
    ['arrived', 'en_route'],
    ['assisting', 'arrived'],
    ['en_route', 'acknowledged'],
    ['assigned', 'acknowledged'],
  ] as const)('backward %s → %s is not allowed', (from, to) => {
    expect(checkTransition(from, to)).toMatchObject({ ok: false, reason: 'not_allowed' });
  });

  it.each(['resolved', 'stood_down'] as const)('%s is terminal for every target', (from) => {
    for (const to of TARGETS) {
      expect(checkTransition(from, to, reassign)).toMatchObject({ ok: false, reason: 'terminal' });
    }
  });

  it.each(['acknowledged', 'en_route', 'arrived', 'assisting'] as const)('repeating %s is a duplicate', (state) => {
    expect(checkTransition(state, state)).toMatchObject({ ok: false, reason: 'duplicate' });
  });

  it('reassigning to the same employee is a duplicate', () => {
    for (const from of ['assigned', 'en_route'] as const) {
      expect(checkTransition(from, 'assigned', { current: 'r1', next: 'r1' })).toMatchObject({
        ok: false,
        reason: 'duplicate',
      });
    }
  });

  it('stand-down is not possible once responders are on scene', () => {
    expect(checkTransition('arrived', 'stood_down').ok).toBe(false);
    expect(checkTransition('assisting', 'stood_down').ok).toBe(false);
  });

  it('the error message lists what is allowed next', () => {
    const result = checkTransition('arrived', 'acknowledged');
    expect(result.ok === false && result.message).toBe('Cannot go from arrived to acknowledged; allowed next: assisting, resolved');
  });

  it('maps the civilian status to a civilian state', () => {
    expect(civilianStateOf('open')).toBe('active');
    expect(civilianStateOf('acknowledged')).toBe('active');
    expect(civilianStateOf('resolved')).toBe('safe');
    expect(civilianStateOf('false_alarm')).toBe('cancelled');
  });
});
