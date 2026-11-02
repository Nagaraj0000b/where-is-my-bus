// Everything about being signed in: talking to /auth, keeping the token
// safe on the phone, and telling the rest of the app who is signed in.
//
// Kept separate from api_client.dart because that file answers questions
// about buses, and this one answers a question about the person holding
// the phone. They happen to use the same server; they are not the same
// concern.
//
// WHAT THE TOKEN IS
//
// When you sign in, the server hands back a long string called a JWT.
// It says "this is user X", and it is signed by the server with a key the
// phone never sees - so the phone cannot make one up, and cannot edit the
// one it has without the signature no longer matching. From then on the
// app attaches it to requests to prove who is asking, instead of sending
// the password again every time. See api/src/auth.ts for the server side.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart' show apiBaseUrl, getApiBaseUrl, ApiUnreachableException;

/// Where the token is kept between app launches.
///
/// flutter_secure_storage, not ordinary preferences. A JWT is a house key
/// - anyone holding it is signed in as you until it expires - so it does
/// not belong in a plain text preferences file that any backup or rooted
/// device can read straight off the disk.
///
/// On Android this package's default already encrypts each value with AES
/// and keeps the key itself in the Android Keystore, so the token is not
/// sitting in readable form anywhere on the device.
///
/// PINNED TO VERSION 9 ON PURPOSE. Version 11 needs Android SDK 37 to
/// build, and the SDK 37 package installed on this machine declares its
/// API level as "37.0" rather than a whole number, which Gradle cannot
/// match - so the build fails looking for a target that is, confusingly,
/// right there. Version 9 builds against SDK 34 and stores the token just
/// as safely. Worth revisiting once a well-formed SDK 37 is installed.
const _secureStorage = FlutterSecureStorage();

const _tokenKey = 'wimb.auth.token';

/// The signed-in person, as the app knows them. Deliberately has no
/// password field of any kind - the app never holds one for longer than
/// the moment it takes to send a sign-in request.
class AuthUser {
  final String userId;
  final String email;
  final String displayName;

  AuthUser({required this.userId, required this.email, required this.displayName});

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      userId: json['userId'] as String,
      email: json['email'] as String,
      displayName: json['displayName'] as String,
    );
  }

  /// The part of the name to greet someone with - "Nagga" out of
  /// "Nagga Sharma". Falls back to the whole thing if there is no space.
  String get firstName {
    final trimmed = displayName.trim();
    final space = trimmed.indexOf(' ');
    return space > 0 ? trimmed.substring(0, space) : trimmed;
  }
}

/// Thrown when the server refuses a sign-in or sign-up and says why - a
/// wrong password, a taken email, a password that is too short.
///
/// Separate from [ApiUnreachableException] because the two need opposite
/// responses: this one means "read the message and fix what you typed",
/// that one means "the server is not there, try again later".
class AuthRejectedException implements Exception {
  final String message;
  AuthRejectedException(this.message);
  @override
  String toString() => message;
}

/// Sends one request to an /auth endpoint and makes sense of the reply.
///
/// All three auth calls have the same shape - post some JSON, expect
/// either a user and a token or an explanation - so the shape lives here
/// once instead of three times.
Future<Map<String, dynamic>> _postToAuth(String path, Map<String, String> body) async {
  await getApiBaseUrl();
  final uri = Uri.parse('$apiBaseUrl$path');

  http.Response response;
  try {
    response = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    throw ApiUnreachableException(
      "Can't reach the API. Is the server running? "
      "($apiBaseUrl)",
    );
  }

  Map<String, dynamic> decoded;
  try {
    decoded = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (_) {
    throw ApiUnreachableException('The server sent something unreadable.');
  }

  // 400/401/409 all mean "the server understood and said no", and it
  // always explains why in `error`. Anything else is a genuine failure.
  if (response.statusCode >= 400) {
    final reason = decoded['error'];
    if (reason is String && reason.isNotEmpty) {
      throw AuthRejectedException(reason);
    }
    throw ApiUnreachableException('Server error (HTTP ${response.statusCode}).');
  }

  return decoded;
}

/// Create an account, and stay signed in afterwards.
Future<AuthUser> signUp({
  required String email,
  required String password,
  required String displayName,
}) async {
  final body = await _postToAuth('/auth/signup', {
    'email': email,
    'password': password,
    'displayName': displayName,
  });

  await _secureStorage.write(key: _tokenKey, value: body['token'] as String);
  return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
}

/// Sign in to an existing account.
Future<AuthUser> logIn({required String email, required String password}) async {
  final body = await _postToAuth('/auth/login', {'email': email, 'password': password});

  await _secureStorage.write(key: _tokenKey, value: body['token'] as String);
  return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
}

/// Forget the token. There is nothing to tell the server about - it never
/// tracked the token, it only checks the signature - so signing out is
/// entirely a matter of the phone throwing its copy away.
Future<void> logOut() async {
  await _secureStorage.delete(key: _tokenKey);
}

/// The saved token, if there is one. Used to attach `Authorization` to
/// requests that need it.
///
/// Never throws. Secure storage genuinely can fail - the Keystore entry
/// can be invalidated when a device's screen lock changes, and in a test
/// environment the plugin is not there at all. In every one of those cases
/// the honest answer is "there is no usable token", which is exactly what
/// no token at all means, so it is treated the same way rather than
/// crashing the app on startup.
Future<String?> savedToken() async {
  try {
    return await _secureStorage.read(key: _tokenKey);
  } catch (_) {
    return null;
  }
}

/// Ask the server who the saved token belongs to.
///
/// Returns null when there is no token, or when the server rejects it -
/// expired, or signed with a different key because the API restarted with
/// a new secret. Either way the honest answer is "not signed in", and the
/// stale token is cleared rather than left to fail again on every launch.
Future<AuthUser?> loadSignedInUser() async {
  final token = await savedToken();
  if (token == null) return null;

  http.Response response;
  try {
    await getApiBaseUrl();
    response = await http.get(
      Uri.parse('$apiBaseUrl/auth/me'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 10));
  } catch (_) {
    // The server being unreachable is NOT proof the token is bad, so it is
    // deliberately kept. Being signed out because the WiFi dropped for a
    // moment would be its own small betrayal.
    return null;
  }

  if (response.statusCode == 401) {
    await logOut();
    return null;
  }
  if (response.statusCode != 200) return null;

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
}

// ---------------------------------------------------------------------------
// The signed-in state, as the widgets see it.
// ---------------------------------------------------------------------------

/// Who is signed in right now.
///
/// `null` means nobody. The provider below is an AsyncValue, so "still
/// checking the saved token" is already represented by its loading state
/// and does not need a third case here.
class AuthController extends AsyncNotifier<AuthUser?> {
  /// Runs once at startup: is there a saved token, and is it still good?
  @override
  Future<AuthUser?> build() async {
    return loadSignedInUser();
  }

  Future<void> signIn({required String email, required String password}) async {
    final user = await logIn(email: email, password: password);
    state = AsyncData(user);
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final user = await signUp(email: email, password: password, displayName: displayName);
    state = AsyncData(user);
  }

  Future<void> signOut() async {
    await logOut();
    state = const AsyncData(null);
  }

  /// Lets someone use the app without an account.
  ///
  /// This is not a fake login and it stores nothing - it simply records,
  /// for this run of the app, that the sign-in screen has been dismissed.
  /// It exists because the app deliberately works without an account (see
  /// db/schema_auth.sql), and forcing a signup before showing a bus time
  /// would contradict that.
  void continueWithoutAccount() {
    _skippedSignIn = true;
    // Reassigning state is what actually notifies the widgets watching
    // this provider - setting the flag alone would change nothing on
    // screen. A fresh AsyncData instance is used rather than the same one
    // so Riverpod sees it as a genuine change.
    state = const AsyncData(null);
  }

  /// Bring the sign-in screen back for someone who skipped it earlier.
  /// The mirror image of [continueWithoutAccount].
  void showSignIn() {
    _skippedSignIn = false;
    state = const AsyncData(null);
  }

  /// Whether the sign-in screen was dismissed during this run. Read by
  /// AuthGate in main.dart to tell "not signed in and has not decided yet"
  /// apart from "not signed in, and that was on purpose".
  bool _skippedSignIn = false;
  bool get skippedSignIn => _skippedSignIn;
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthUser?>(AuthController.new);

/// True once the app has finished deciding whether anyone is signed in -
/// used to hold the splash screen until the answer is known, rather than
/// showing the sign-in screen for a moment and then snatching it away.
final authResolvedProvider = Provider<bool>((ref) {
  return !ref.watch(authControllerProvider).isLoading;
});

/// Debug helper: prints the current sign-in state. Only ever called from
/// debug builds, so it costs nothing in a release build.
void debugLogAuth(AuthUser? user) {
  if (kDebugMode) {
    debugPrint(user == null ? '[auth] signed out' : '[auth] signed in as ${user.email}');
  }
}
