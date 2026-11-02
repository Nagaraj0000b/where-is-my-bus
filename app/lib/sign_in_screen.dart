// Signing in and creating an account.
//
// One screen does both, with a toggle, rather than two screens and a link
// between them. Someone who mistypes their email on the sign-in form and
// discovers they never had an account should not lose what they typed just
// to get to a signup form.
//
// The "continue without an account" button at the bottom is the important
// one, and it is deliberately not hidden away. This app works perfectly
// well for a stranger - accounts only buy saved places and the ability to
// report a bus. Demanding a signup before showing anyone a bus time would
// be exactly the kind of user-hostile behaviour the project exists to push
// back on.
//
// LAYOUT
//
// A phone-first sign-in: brand at the top, one plain statement of purpose,
// one white form card, one full-width primary button, and the escape hatch
// as an equally large outlined button below it - not a tiny text link lost
// under a form.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_client.dart';
import 'theme.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  /// false = signing in to an existing account, true = making a new one.
  /// The same form serves both; only the name field and the wording change.
  bool _creatingAccount = false;

  bool _busy = false;
  String? _errorMessage;
  bool _passwordHidden = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Checks the form here before bothering the server.
  ///
  /// These rules are deliberately the same as the ones in api/src/auth.ts.
  /// The server's copy is the one that actually protects anything - this
  /// copy just means an obvious mistake gets an instant answer instead of a
  /// round trip. If the two ever disagree, the server wins.
  String? _localProblem() {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) return 'Enter your email address.';
    if (!email.contains('@') || !email.contains('.')) {
      return 'That does not look like an email address.';
    }
    if (password.isEmpty) return 'Enter your password.';
    if (_creatingAccount && password.length < 8) {
      return 'Password must be at least 8 characters.';
    }
    if (_creatingAccount && _nameController.text.trim().isEmpty) {
      return 'Enter your name.';
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _localProblem();
    if (problem != null) {
      setState(() => _errorMessage = problem);
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final controller = ref.read(authControllerProvider.notifier);
      if (_creatingAccount) {
        await controller.register(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _nameController.text.trim(),
        );
      } else {
        await controller.signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
      // On success the auth state changes and main.dart swaps this screen
      // out, so there is nothing to do here.
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WimbColors.cream,
      body: SafeArea(
        // A plain scrolling column, not a lazy list: a sign-in form is
        // short enough that building all of it costs nothing, and it means
        // the escape hatch below the form is always laid out even on a
        // short screen.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              const SizedBox(height: 18),
              _formCard(context),
              const SizedBox(height: 12),
              _withoutAccountButton(context),
            ],
          ),
        ),
      ),
    );
  }

  /// The wordmark and the one-line statement of what the app is for.
  Widget _header(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const WimbWordmark(color: WimbColors.ink),
        const SizedBox(height: 18),
        Text(
          'Honest bus times, not guesses.',
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Every arrival comes as a range, with a plain note on how much to '
          'trust it. No single number pretending to be certain.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: WimbColors.inkMuted,
              ),
        ),
      ],
    );
  }

  Widget _formCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionLabel(_creatingAccount ? 'Create an account' : 'Sign in'),

            // Only appears when making a new account.
            if (_creatingAccount) ...[
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 12),
            ],

            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _passwordController,
              obscureText: _passwordHidden,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: _creatingAccount ? 'At least 8 characters.' : null,
                suffixIcon: IconButton(
                  icon: Icon(
                    _passwordHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    color: WimbColors.inkMuted,
                  ),
                  onPressed: () => setState(() => _passwordHidden = !_passwordHidden),
                  tooltip: _passwordHidden ? 'Show password' : 'Hide password',
                ),
              ),
              // Enter on the keyboard submits, rather than making someone
              // dismiss it to reach the button.
              onSubmitted: (_) => _busy ? null : _submit(),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              _errorBox(context, _errorMessage!),
            ],

            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : Text(_creatingAccount ? 'Create account' : 'Sign in'),
            ),

            const SizedBox(height: 4),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _creatingAccount = !_creatingAccount;
                        // The old message almost certainly referred to the
                        // other mode, so it would only confuse now.
                        _errorMessage = null;
                      }),
              child: Text(
                _creatingAccount
                    ? 'I already have an account'
                    : "I'm new here - create an account",
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBox(BuildContext context, String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: WimbColors.dtcRed.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(WimbRadius.field),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: WimbColors.dtcRed),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: WimbColors.dtcRedDark, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// The escape hatch. Given the same width and almost the same height as
  /// the primary button, because for a stranger it IS the primary action.
  Widget _withoutAccountButton(BuildContext context) {
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => ref.read(authControllerProvider.notifier).continueWithoutAccount(),
          icon: const Icon(Icons.person_outline, size: 19),
          style: OutlinedButton.styleFrom(
            foregroundColor: WimbColors.ink,
            backgroundColor: WimbColors.cardCream,
            minimumSize: const Size.fromHeight(52),
          ),
          label: const Text('Continue without an account'),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'Finding a bus never needs an account. Signing in only adds '
            'saved places and lets you report a bus that the feed has '
            'missed.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
