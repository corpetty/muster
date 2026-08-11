#ifndef ERROR_LOG_H
#define ERROR_LOG_H

#include <QList>
#include <QString>
#include <QVariantList>

class QDateTime;

// Every failure a run reported, newest first, so a reader sees the whole run
// rather than whichever failure happened to be on the strip last.
//
// Consecutive repeats of one message collapse into a single entry carrying how
// many times it arrived: a reconnect storm reads as one line with a count rather
// than as fifty lines of history.
class ErrorLog
{
public:
    // Entries kept, newest. A burst is otherwise unbounded, and this is far more
    // than triaging a session takes.
    static constexpr int kMaxEntries = 200;

    // Records a failure at `when`. Repeating the newest message counts against
    // that entry instead of adding one.
    void add(const QString& message, const QDateTime& when);

    // One map per entry, newest first: `when`, `message`, and `count`.
    QVariantList published() const;

private:
    struct Entry {
        QString when;
        QString message;
        int count = 1;
    };

    // Oldest first, so a repeat lands on the back and the cap drops the front;
    // `published` reverses.
    QList<Entry> m_entries;
};

#endif
