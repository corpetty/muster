#include "TimeFormat.h"

#include <QDateTime>
#include <QLocale>

namespace {

// Drop the seconds field, and the separator introducing it, from a time format
// pattern. Only an unquoted "s" run is the seconds field: a quoted section is
// literal text that may contain anything.
QString withoutSeconds(const QString& pattern)
{
    QString out;
    out.reserve(pattern.size());
    bool quoted = false;
    for (int i = 0; i < pattern.size(); ++i) {
        const QChar c = pattern.at(i);
        if (c == u'\'') {
            quoted = !quoted;
            out.append(c);
        } else if (!quoted && c == u's') {
            while (!out.isEmpty() && !out.back().isLetterOrNumber() && out.back() != u'\'')
                out.chop(1);
            while (i + 1 < pattern.size() && pattern.at(i + 1) == u's')
                ++i;
        } else {
            out.append(c);
        }
    }
    return out;
}

} // namespace

namespace TimeFormat {

QString shortTime(const QDateTime& when)
{
    if (!when.isValid())
        return {};

    // Some locales, the C locale among them, carry seconds in their short time
    // format. Chat timestamps are minute-resolution.
    const QLocale locale = QLocale::system();
    return locale.toString(when.time(), withoutSeconds(locale.timeFormat(QLocale::ShortFormat)));
}

} // namespace TimeFormat
