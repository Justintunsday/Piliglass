import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/accounts/account_request_state.dart';

int _checks = 0;
final _observations = <Map<String, Object?>>[];

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
  _checks++;
}

void expectMissingSetter(void Function() mutation, String message) {
  try {
    mutation();
  } on NoSuchMethodError {
    _checks++;
    return;
  }
  throw StateError(message);
}

final class _EqualAccount {
  const _EqualAccount(this.mid, this.label);

  final int mid;
  final String label;

  @override
  bool operator ==(Object other) => other is _EqualAccount && mid == other.mid;

  @override
  int get hashCode => mid.hashCode;
}

Future<bool> completeWhenReleased<T extends Object>(
  AccountRequestState<T> state,
  AccountRequestStamp<T> stamp,
  Completer<void> release,
) async {
  await release.future;
  return state.isCurrent(stamp);
}

void identityChecks() {
  final state = AccountRequestState<_EqualAccount>();
  const a = _EqualAccount(7, 'old credentials');
  const b = _EqualAccount(7, 'new credentials');
  expect(a == b && a.hashCode == b.hashCode, 'Fixture accounts compare equal');
  expect(!identical(a, b), 'Fixture accounts have distinct identities');
  expect(state.revision == 0, 'A fresh tracker has revision zero');
  expect(state.capture(a) == null, 'Capture does not install unknown accounts');
  expect(state.revision == 0, 'An unknown capture does not change revision');

  final aStamp = state.activate(a);
  final afterA = state.revision;
  final bStamp = state.activate(b);
  expect(afterA > 0, 'First activation changes preparation revision');
  expect(
    state.revision > afterA,
    'Distinct identity activation changes revision',
  );
  expect(
    identical(aStamp.account, a),
    'A stamp retains the original A identity',
  );
  expect(
    identical(bStamp.account, b),
    'B stamp retains the original B identity',
  );
  expect(!identical(aStamp, bStamp), 'Equal accounts receive distinct stamps');
  expect(
    identical(state.capture(a), aStamp),
    'Equal B does not replace A capture',
  );
  expect(identical(state.capture(b), bStamp), 'B capture retains B generation');
  expect(
    state.isCurrent(aStamp) && state.isCurrent(bStamp),
    'Both equal identities remain installed',
  );

  final revision = state.revision;
  expect(
    identical(state.activate(a), aStamp),
    'Repeated activation returns A stamp',
  );
  expect(
    identical(state.activate(b), bStamp),
    'Repeated activation returns B stamp',
  );
  expect(
    state.revision == revision,
    'Repeated activation does not change revision',
  );
  expect(
    state.isCurrent(aStamp) && state.isCurrent(bStamp),
    'Repeated scans preserve in-flight stamps',
  );

  state.revoke(a);
  expect(state.revision > revision, 'An effective revocation changes revision');
  expect(
    state.capture(a) == null && !state.isCurrent(aStamp),
    'Revocation removes A capture and invalidates A',
  );
  expect(
    identical(state.capture(b), bStamp) && state.isCurrent(bStamp),
    'Revoking equal A preserves B identity',
  );
  final replacement = state.activate(a);
  expect(
    replacement.generation != aStamp.generation,
    'Reinstallation allocates a new generation',
  );
  expect(
    !identical(replacement, aStamp),
    'Reinstallation allocates a new stamp',
  );
  expect(!state.isCurrent(aStamp), 'Reinstallation never revives an old stamp');
  expect(state.isCurrent(replacement), 'Reinstalled A is current');
  _observations.add({
    'scenario': 'equal_accounts_identity_and_reinstall',
    'oldGeneration': aStamp.generation,
    'newGeneration': replacement.generation,
    'revision': state.revision,
  });
}

Future<void> selectionAndCookieChecks() async {
  final state = AccountRequestState<Object>();
  final a = Object();
  final b = Object();
  final aStamp = state.activate(a);
  final bStamp = state.activate(b);
  var selected = a;
  final preparedRevision = state.revision;
  final aRelease = Completer<void>();
  final bRelease = Completer<void>();
  final aResponse = completeWhenReleased(state, aStamp, aRelease);
  final bResponse = completeWhenReleased(state, bStamp, bRelease);

  expect(
    identical(state.capture(selected), aStamp),
    'Initial selection captures A',
  );
  selected = b;
  state.changed();
  final afterB = state.revision;
  expect(
    afterB > preparedRevision,
    'A to B selection invalidates preparation revision',
  );
  expect(
    identical(state.capture(selected), bStamp),
    'B selection captures original B stamp',
  );
  selected = a;
  state.changed();
  expect(state.revision > afterB, 'B to A selection changes revision again');
  expect(
    identical(state.capture(selected), aStamp),
    'A to B to A preserves A generation',
  );
  expect(
    state.isCurrent(aStamp) && state.isCurrent(bStamp),
    'Switching selection preserves both pending responses',
  );

  final beforeCookie = state.revision;
  state.changed();
  expect(
    state.revision > beforeCookie,
    'An ordinary Cookie update invalidates preparation revision',
  );
  expect(
    state.isCurrent(aStamp) && state.isCurrent(bStamp),
    'Cookie change preserves both pending generations',
  );
  aRelease.complete();
  expect(
    await aResponse,
    'A response completes after selection and Cookie changes',
  );
  final beforeACookie = state.revision;
  state.changed();
  expect(
    state.revision > beforeACookie,
    'A response Cookie write changes preparation revision',
  );
  bRelease.complete();
  expect(
    await bResponse,
    'B response remains valid after A response Cookie change',
  );
  _observations.add({
    'scenario': 'a_b_a_and_concurrent_cookie_responses',
    'preparedRevision': preparedRevision,
    'finishedRevision': state.revision,
    'aResponseAccepted': true,
    'bResponseAccepted': true,
  });
}

Future<void> revokeAllChecks() async {
  final state = AccountRequestState<Object>();
  final selected = Object();
  final unselected = Object();
  final selectedStamp = state.activate(selected);
  final unselectedStamp = state.activate(unselected);
  final selectedRelease = Completer<void>();
  final unselectedRelease = Completer<void>();
  final selectedResponse = completeWhenReleased(
    state,
    selectedStamp,
    selectedRelease,
  );
  final unselectedResponse = completeWhenReleased(
    state,
    unselectedStamp,
    unselectedRelease,
  );
  final revision = state.revision;

  state.revokeAll();
  expect(state.revision > revision, 'Revoke all changes preparation revision');
  expect(
    state.capture(selected) == null && state.capture(unselected) == null,
    'Revoke all removes selected and unselected identities',
  );
  selectedRelease.complete();
  unselectedRelease.complete();
  expect(
    !(await selectedResponse),
    'Revoke all rejects selected pending response',
  );
  expect(
    !(await unselectedResponse),
    'Revoke all rejects unselected pending response',
  );

  final reinstalled = state.activate(unselected);
  expect(
    reinstalled.generation != unselectedStamp.generation,
    'Reinstall after revoke all gets a new generation',
  );
  expect(
    !state.isCurrent(unselectedStamp),
    'Reinstall after revoke all never revives old response',
  );
  expect(state.isCurrent(reinstalled), 'Reinstall after revoke all is current');
  _observations.add({
    'scenario': 'revoke_all_including_unselected',
    'selectedResponseAccepted': false,
    'unselectedResponseAccepted': false,
    'oldUnselectedGeneration': unselectedStamp.generation,
    'newUnselectedGeneration': reinstalled.generation,
  });
}

void anonymousChecks() {
  final state = AccountRequestState<Object>();
  final anonymous = Object();
  final first = state.activate(anonymous);
  var previous = first;
  for (var reset = 0; reset < 3; reset++) {
    state.revoke(anonymous);
    expect(
      state.capture(anonymous) == null,
      'Anonymous reset leaves generation inactive until activation',
    );
    state.changed();
    expect(
      !state.isCurrent(previous),
      'Anonymous reset Cookie change does not reinstall credentials',
    );
    final replacement = state.activate(anonymous);
    expect(
      identical(replacement.account, anonymous),
      'Anonymous reset reuses the singleton account identity',
    );
    expect(
      replacement.generation != previous.generation,
      'Anonymous singleton gets a new generation on each reset',
    );
    expect(
      !state.isCurrent(previous) && !state.isCurrent(first),
      'Anonymous reset never revives any previous generation',
    );
    expect(
      state.isCurrent(replacement),
      'Completed anonymous reset enables the new generation',
    );
    previous = replacement;
  }
  _observations.add({
    'scenario': 'anonymous_same_identity_repeated_reset',
    'firstGeneration': first.generation,
    'lastGeneration': previous.generation,
    'resets': 3,
  });
}

void stampChecks() {
  final firstState = AccountRequestState<Object>();
  final secondState = AccountRequestState<Object>();
  final account = Object();
  final first = firstState.activate(account);
  final second = secondState.activate(account);
  expect(
    first.generation == second.generation,
    'Cross-tracker fixture has colliding numeric generations',
  );
  expect(
    !firstState.isCurrent(second) && !secondState.isCurrent(first),
    'Cross-tracker stamps are rejected for the same account',
  );
  expect(
    firstState.isCurrent(first) && secondState.isCurrent(second),
    'Each tracker recognizes only its own stamp',
  );
  final copied = <AccountRequestStamp<Object>>[first].single;
  final capturedGeneration = copied.generation;
  expect(
    identical(copied, first),
    'Retaining a stamp copies its immutable reference',
  );
  final dynamic dynamicStamp = copied;
  expectMissingSetter(
    () => dynamicStamp.account = Object(),
    'A stamp unexpectedly allowed its account identity to change',
  );
  expectMissingSetter(
    () => dynamicStamp.generation = capturedGeneration + 1,
    'A stamp unexpectedly allowed its generation to change',
  );
  expect(
    identical(copied.account, account),
    'Mutation attempt preserves the captured account identity',
  );
  expect(
    copied.generation == capturedGeneration,
    'Mutation attempt preserves the captured generation',
  );
  firstState.revoke(account);
  final reinstalled = firstState.activate(account);
  expect(
    copied.generation == capturedGeneration,
    'Reinstallation does not mutate a retained stamp',
  );
  expect(
    !firstState.isCurrent(copied),
    'A retained copy cannot regain validity after reinstallation',
  );
  expect(
    firstState.isCurrent(reinstalled),
    'The reinstalled stamp remains valid after mutation attempts',
  );
  expect(
    secondState.isCurrent(second),
    'Revocation in one tracker preserves the other tracker',
  );
  _observations.add({
    'scenario': 'cross_tracker_and_immutable_stamp',
    'capturedGeneration': capturedGeneration,
    'reinstalledGeneration': reinstalled.generation,
    'accountSetterRejected': true,
    'generationSetterRejected': true,
  });
}

Future<void> main() async {
  final output = Directory('build/account-request-state')
    ..createSync(recursive: true);
  Object? failure;
  StackTrace? failureStack;
  try {
    identityChecks();
    await selectionAndCookieChecks();
    await revokeAllChecks();
    anonymousChecks();
    stampChecks();
  } catch (error, stack) {
    failure = error;
    failureStack = stack;
  }

  final report = {
    'status': failure == null ? 'passed' : 'failed',
    'checks': _checks,
    'dartVersion': Platform.version,
    'observations': _observations,
    if (failure != null) 'error': failure.toString(),
    if (failureStack != null) 'stack': failureStack.toString(),
  };
  final json = const JsonEncoder.withIndent('  ').convert(report);
  File('${output.path}/summary.json').writeAsStringSync('$json\n');
  if (failure != null) {
    stderr.writeln(
      'Account request state fixture failed after $_checks checks: $failure',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln('$_checks account request state checks passed');
}
