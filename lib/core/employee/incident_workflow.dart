// UI-side view of the responder state machine
// (backend/src/services/incidentStateMachine.ts). It only decides which
// buttons to show; the backend validates every transition and permission
// and rejects anything else with 409 INVALID_TRANSITION or 403.

import 'operations_api.dart';

const responderStates = [
  'reported',
  'acknowledged',
  'assigned',
  'en_route',
  'arrived',
  'assisting',
  'resolved',
  'stood_down'
];
const terminalResponderStates = {'resolved', 'stood_down'};

const responderTransitions = <String, List<String>>{
  'reported': ['acknowledged', 'assigned', 'stood_down'],
  'acknowledged': ['assigned', 'stood_down'],
  'assigned': ['en_route', 'assigned', 'stood_down'],
  'en_route': ['arrived', 'assigned', 'stood_down'],
  'arrived': ['assisting', 'resolved'],
  'assisting': ['resolved'],
  'resolved': [],
  'stood_down': [],
};

String responderStateLabel(String state) => switch (state) {
      'reported' => 'Unacknowledged',
      'acknowledged' => 'Acknowledged',
      'assigned' => 'Assigned',
      'en_route' => 'En route',
      'arrived' => 'On scene',
      'assisting' => 'Assisting',
      'resolved' => 'Resolved',
      'stood_down' => 'Stood down',
      _ => state,
    };

String civilianStateLabel(String state) => switch (state) {
      'active' => 'Needs help',
      'safe' => 'Marked safe',
      'cancelled' => 'Cancelled by reporter',
      _ => state,
    };

/// Button label for moving an incident to [state].
String actionLabel(String state, {bool reassign = false}) => switch (state) {
      'acknowledged' => 'Acknowledge',
      'assigned' => reassign ? 'Reassign' : 'Assign',
      'en_route' => 'Mark en route',
      'arrived' => 'Mark on scene',
      'assisting' => 'Mark assisting',
      'resolved' => 'Resolve',
      'stood_down' => 'Stand down',
      _ => state,
    };

class IncidentActor {
  const IncidentActor({required this.employeeId, required this.canRespond, required this.canAssign});
  final String employeeId;
  final bool canRespond;
  final bool canAssign;
}

/// State changes this employee may request from [opsStatus], in display order.
/// Mirrors the backend rules:
/// - everything needs SOS_RESPOND;
/// - assign/reassign and stand-down also need SOS_ASSIGN;
/// - en route / on scene / assisting / resolved are for the assignee, or
///   someone with SOS_ASSIGN recording on their behalf.
List<String> availableTransitions(
    {required String opsStatus, required String? assignedEmployeeId, required IncidentActor actor}) {
  if (!actor.canRespond) return const [];
  final next = responderTransitions[opsStatus] ?? const <String>[];
  final isAssignee = assignedEmployeeId != null && assignedEmployeeId == actor.employeeId;
  return next.where((to) {
    if (to == 'assigned' || to == 'stood_down') return actor.canAssign;
    if (to == 'acknowledged') return true;
    return isAssignee || actor.canAssign;
  }).toList();
}

bool canAddNote(IncidentActor actor) => actor.canRespond;

/// Human-readable description of a timeline entry.
String describeTimelineEntry(TimelineEntry entry, {String? Function(String? id)? nameOf}) {
  final who = nameOf?.call(entry.employeeId) ?? 'A responder';
  switch (entry.action) {
    case 'civilian_state':
      return switch (entry.newState) {
        'safe' => 'Reporter marked themselves safe',
        'cancelled' => 'Reporter cancelled the SOS',
        'active' => 'Reporter reactivated the SOS',
        _ => 'Reporter changed their status',
      };
    case 'note':
      return '$who added a note';
    case 'assigned':
      final assignee = nameOf?.call(entry.assignedEmployeeId) ?? 'a responder';
      return entry.previousState == 'assigned' || entry.previousState == 'en_route'
          ? '$who reassigned the incident to $assignee'
          : '$who assigned the incident to $assignee';
    default:
      return '$who: ${responderStateLabel(entry.newState ?? entry.action)}';
  }
}
