#ifndef IDENTITY_H
#define IDENTITY_H

#include <QString>

namespace Identity {

// How many avatar colour ramps an identity can land in. The view's ramp table
// (ChatUi's ChatTheme.avatarRamps) carries exactly this many entries.
constexpr int kAvatarRampCount = 5;

// Short form of an account address, the identity string every surface shows in
// place of the full address. Empty for an empty address; a caller that must
// name an unknown account substitutes its own wording.
QString shortLabel(const QString& address);

// Two-letter form of an identity, the label an avatar carries.
QString initials(const QString& identity);

// Colour ramp for an identity, in [0, kAvatarRampCount). Stable across runs and
// installations, so one account keeps one colour wherever it is drawn.
int avatarRamp(const QString& identity);

} // namespace Identity

#endif
