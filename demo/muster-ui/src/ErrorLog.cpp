#include "ErrorLog.h"

#include <QDateTime>
#include <QVariantMap>

namespace {

// Seconds and all: two failures a second apart are ordinary in a burst, and a
// clock that cannot tell them apart makes the list look like it repeated itself.
// The locale's short form drops seconds, which is why it is not used here.
QString clockTime(const QDateTime& when)
{
    return when.toString(QStringLiteral("HH:mm:ss"));
}

} // namespace

void ErrorLog::add(const QString& message, const QDateTime& when)
{
    if (!m_entries.isEmpty() && m_entries.last().message == message) {
        ++m_entries.last().count;
        // The time stays the first occurrence's: the row says when the failure
        // started, and the count says it has not stopped.
        return;
    }

    m_entries.append({clockTime(when), message, 1});
    if (m_entries.size() > kMaxEntries)
        m_entries.removeFirst();
}

QVariantList ErrorLog::published() const
{
    QVariantList published;
    published.reserve(m_entries.size());
    for (auto entry = m_entries.crbegin(); entry != m_entries.crend(); ++entry) {
        published.append(QVariantMap{
            {QStringLiteral("when"), entry->when},
            {QStringLiteral("message"), entry->message},
            {QStringLiteral("count"), entry->count},
        });
    }
    return published;
}
