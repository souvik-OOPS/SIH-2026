/// Escalating retry schedule for a link that keeps failing to come back.
///
/// A fixed-interval rescan keeps the BLE radio busy indefinitely and is the
/// usual cause of a phone going flat next to a switched-off wearable. Each
/// unsuccessful attempt doubles the wait up to [max]; a successful connection
/// calls [reset] so the next outage is retried promptly again.
class ReconnectBackoff {
  ReconnectBackoff({
    this.initial = const Duration(seconds: 4),
    this.max = const Duration(seconds: 60),
  }) : assert(initial > Duration.zero, 'initial delay must be positive'),
       assert(max >= initial, 'max delay cannot be shorter than initial'),
       _current = initial;

  final Duration initial;
  final Duration max;

  Duration _current;

  /// The delay to wait before the next attempt.
  Duration get current => _current;

  /// Returns the delay to use now, then escalates for the attempt after it.
  Duration next() {
    final delay = _current;
    final doubled = _current * 2;
    _current = doubled > max ? max : doubled;
    return delay;
  }

  /// Called once a link is healthy again, so the next outage retries quickly.
  void reset() => _current = initial;
}
