// Shared error display, used by every screen that can fail.
//
// It carries a distinction the app cares about: an honest "no route found"
// is NOT a failure, and offering to retry it would be a lie - the same
// question asked again gets the same honest answer. Only a genuine request
// failure gets a "Try again" button. See the call sites for which is which.
//
// Layout: an icon in a tinted circle, the message, and the retry action on
// its own line. A phone card cannot hold a long Delhi error sentence and a
// button side by side without squeezing both.

import 'package:flutter/material.dart';

import 'theme.dart';

class ErrorCard extends StatelessWidget {
  final String message;

  /// Null means "do not offer to retry" - the honest-answer case above.
  final VoidCallback? onRetry;

  const ErrorCard({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    // A retryable failure is the app's problem and is drawn in the alarm
    // colour. An honest "there is no route" is not an error at all, so it
    // is drawn quietly, in ordinary card colours - shouting at someone in
    // red because Delhi has no bus between two places would be blaming
    // them for the city.
    final isRealFailure = onRetry != null;
    final accent = isRealFailure ? WimbColors.dtcRed : WimbColors.inkMuted;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isRealFailure ? Icons.cloud_off : Icons.search_off,
                    size: 19,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: isRealFailure ? WimbColors.dtcRedDark : WimbColors.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
