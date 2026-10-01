// Two independent states per SOS event:
//
// - civilian state: what the person in distress (or their own device) says.
//   Stored in sos_events.status; only the reporter changes it.
//     open / acknowledged → 'active', resolved → 'safe', false_alarm → 'cancelled'
// - responder state: operations progress, sos_events.ops_status; only
//   employees change it, through the transitions below.
//
// A civilian marking themselves safe never changes the responder state:
// once responders are involved, only a responder closes the incident
// ('resolved' after attending, or 'stood_down' with a reason).

export const RESPONDER_STATES = [
  'reported', // unacknowledged
  'acknowledged',
  'assigned',
  'en_route',
  'arrived',
  'assisting',
  'resolved',
  'stood_down',
] as const;
export type ResponderState = (typeof RESPONDER_STATES)[number];
export type ResponderTransition = Exclude<ResponderState, 'reported'>;

export type CivilianState = 'active' | 'safe' | 'cancelled';

export function civilianStateOf(status: string): CivilianState {
  if (status === 'resolved') return 'safe';
  if (status === 'false_alarm') return 'cancelled';
  return 'active';
}

export const TERMINAL_RESPONDER_STATES: readonly ResponderState[] = ['resolved', 'stood_down'];

/**
 * Allowed next states. Justifications for the non-linear edges:
 * - reported → assigned: a dispatcher assigning a new SOS has acknowledged it.
 * - assigned/en_route → assigned: reassignment when the responder can't
 *   continue (must name a different employee).
 * - arrived → resolved: on scene, no further assistance needed.
 * - → stood_down: closing without attending (duplicate report, person
 *   confirmed safe, cancelled). Only before arrival; needs a reason.
 * Nothing leaves 'resolved' or 'stood_down'.
 */
export const RESPONDER_TRANSITIONS: Readonly<Record<ResponderState, readonly ResponderState[]>> = {
  reported: ['acknowledged', 'assigned', 'stood_down'],
  acknowledged: ['assigned', 'stood_down'],
  assigned: ['en_route', 'assigned', 'stood_down'],
  en_route: ['arrived', 'assigned', 'stood_down'],
  arrived: ['assisting', 'resolved'],
  assisting: ['resolved'],
  resolved: [],
  stood_down: [],
};

export type TransitionCheck =
  | { ok: true }
  | { ok: false; reason: 'terminal' | 'duplicate' | 'not_allowed'; message: string };

export function checkTransition(
  from: ResponderState,
  to: ResponderTransition,
  assignees: { current: string | null; next?: string } = { current: null },
): TransitionCheck {
  if (TERMINAL_RESPONDER_STATES.includes(from)) {
    return { ok: false, reason: 'terminal', message: `The incident is ${from}; only notes can be added` };
  }
  const isReassignment = from === 'assigned' || from === 'en_route';
  if (to === 'assigned' && isReassignment && assignees.next !== undefined && assignees.next === assignees.current) {
    return { ok: false, reason: 'duplicate', message: 'The incident is already assigned to this employee' };
  }
  if (from === to && to !== 'assigned') {
    return { ok: false, reason: 'duplicate', message: `The incident is already ${from}` };
  }
  if (!RESPONDER_TRANSITIONS[from].includes(to)) {
    const allowed = RESPONDER_TRANSITIONS[from].join(', ');
    return { ok: false, reason: 'not_allowed', message: `Cannot go from ${from} to ${to}; allowed next: ${allowed}` };
  }
  return { ok: true };
}
