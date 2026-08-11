#include "ProcessLog.h"

#include "RunLog.h"

#include <QDateTime>
#include <QMutexLocker>
#include <QRecursiveMutex>
#include <QStringList>
#include <QtGlobal>

#include <utility>

namespace {

// Lines held while no directory is known. Capped, because a run that never
// learns one would otherwise grow a buffer for as long as it lives; what the cap
// drops is said in the file rather than lost quietly.
constexpr int kMaxBuffered = 200;

// Guards everything below: a Qt message handler is called from whichever thread
// logged. Recursive, with `writing` for the one case recursion can arise: a file
// operation that fails and logs the failure, which must reach the previous
// handler without re-entering the writer that is failing.
QRecursiveMutex mutex;
bool writing = false;

RunLog runLog;
QStringList buffered;
int dropped = 0;
QtMessageHandler previousHandler = nullptr;
bool installed = false;

// Qt's own words for its levels, so a reader ranks a line the way Qt did.
QString severityOf(QtMsgType type)
{
    switch (type) {
    case QtDebugMsg:
        return QStringLiteral("DEBUG");
    case QtInfoMsg:
        return QStringLiteral("INFO");
    case QtWarningMsg:
        return QStringLiteral("WARNING");
    case QtCriticalMsg:
        return QStringLiteral("CRITICAL");
    case QtFatalMsg:
        return QStringLiteral("FATAL");
    }
    return QStringLiteral("INFO");
}

QString now()
{
    return QDateTime::currentDateTime().toString(Qt::ISODateWithMs);
}

// `<time> <SEVERITY>: <category>: <message>`, one line per message.
QString lineFor(QtMsgType type, const QMessageLogContext& context, const QString& message)
{
    const QString category =
        context.category ? QString::fromUtf8(context.category) : QStringLiteral("default");
    return QStringLiteral("%1 %2: %3: %4").arg(now(), severityOf(type), category, message);
}

void handle(QtMsgType type, const QMessageLogContext& context, const QString& message)
{
    {
        QMutexLocker locker(&mutex);
        // A line raised by the writer's own failure is not one the writer can
        // take; it goes to the previous handler and no further.
        if (!writing) {
            writing = true;
            const QString line = lineFor(type, context, message);
            if (runLog.isOpen())
                runLog.write(line);
            else if (buffered.size() < kMaxBuffered)
                buffered.append(line);
            else
                ++dropped;
            writing = false;
        }
    }

    // Outside the lock, and unconditional: whatever used to carry these lines
    // goes on carrying them.
    if (previousHandler)
        previousHandler(type, context, message);
}

} // namespace

void ProcessLog::install()
{
    QMutexLocker locker(&mutex);
    if (installed)
        return;
    installed = true;
    previousHandler = qInstallMessageHandler(handle);
}

bool ProcessLog::openIn(const QString& directory)
{
    QMutexLocker locker(&mutex);
    // The stem this writer's runs are grouped by. The chat module keeps its own
    // log in the same directory under its own, and neither list picks up the
    // other's files.
    writing = true;
    const bool opened = runLog.open(directory, QStringLiteral("chat_ui"));
    if (opened) {
        for (const QString& line : std::as_const(buffered))
            runLog.write(line);
        buffered.clear();
        if (dropped > 0) {
            runLog.write(QStringLiteral("%1 WARNING: chat_ui: %2 lines were logged before this "
                                        "file could be opened and are not in it")
                             .arg(now())
                             .arg(dropped));
            dropped = 0;
        }
    }
    writing = false;
    return opened;
}

QString ProcessLog::path()
{
    QMutexLocker locker(&mutex);
    return runLog.path();
}
