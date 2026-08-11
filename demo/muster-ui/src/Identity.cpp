#include "Identity.h"

namespace {

constexpr int kShortLabelChars = 8;
constexpr int kInitialsChars = 2;

} // namespace

QString Identity::shortLabel(const QString& address)
{
    return address.left(kShortLabelChars);
}

QString Identity::initials(const QString& identity)
{
    return identity.left(kInitialsChars).toLower();
}

int Identity::avatarRamp(const QString& identity)
{
    // FNV-1a rather than qHash: Qt seeds qHash per process, which would repaint
    // every avatar on restart and disagree between two instances of the app.
    quint32 hash = 2166136261u;
    for (const char byte : identity.toUtf8())
        hash = (hash ^ static_cast<quint8>(byte)) * 16777619u;
    return static_cast<int>(hash % static_cast<quint32>(kAvatarRampCount));
}
