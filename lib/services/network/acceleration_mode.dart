/// Shared shape for the "acceleration" pickers used by the network settings.
///
/// Each concrete enum supplies its own [label] and [description] so the same
/// dialog and settings tile can render every mode list without special cases.
abstract interface class AccelerationMode implements Enum {
  String get label;

  String get description;
}
