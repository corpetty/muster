#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTest>

#include "RunLog.h"
#include "SessionLogFiles.h"

class TestRunLog : public QObject
{
    Q_OBJECT

private slots:
    void namesItsFileAfterItsStem();
    void refusesADirectoryItCannotMake();
    void movesAFullFileAsideAndKeepsTheAnnouncedPath();
    void prunesToTheNewestRunsAndLeavesAnotherWritersAlone();

private:
    static void writeLines(RunLog& log, int count);
    static QStringList namesIn(const QString& directory);
    // A file of a run that is over, so pruning has something to count.
    static void placeRun(const QString& directory, const QString& stem, const QString& stamp);
};

void TestRunLog::writeLines(RunLog& log, int count)
{
    for (int i = 0; i < count; ++i)
        log.write(QStringLiteral("WARNING: default: something happened"));
}

QStringList TestRunLog::namesIn(const QString& directory)
{
    QStringList names = QDir(directory).entryList(QDir::Files, QDir::Name);
    names.sort();
    return names;
}

void TestRunLog::placeRun(const QString& directory, const QString& stem, const QString& stamp)
{
    QFile file(QDir(directory).filePath(QStringLiteral("%1_%2.log").arg(stem, stamp)));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("x");
}

void TestRunLog::namesItsFileAfterItsStem()
{
    QTemporaryDir dir;
    RunLog log;

    QVERIFY(log.open(dir.path(), QStringLiteral("chat_ui")));

    QVERIFY(log.isOpen());
    const QString name = QFileInfo(log.path()).fileName();
    QVERIFY2(name.startsWith(QStringLiteral("chat_ui_")), qPrintable(name));
    QVERIFY2(name.endsWith(QStringLiteral(".log")), qPrintable(name));
    // The naming a reader groups a directory's runs by, so a run it opened is a
    // run the dialog can list.
    QCOMPARE(listSessionLogRuns(log.path()).size(), 1);
}

void TestRunLog::refusesADirectoryItCannotMake()
{
    RunLog log;

    QVERIFY(!log.open(QString(), QStringLiteral("chat_ui")));

    QVERIFY(!log.isOpen());
    QVERIFY(log.path().isEmpty());
    // Writing anyway is a no-op rather than a crash: the caller reports the
    // failure and carries on.
    log.write(QStringLiteral("a line with nowhere to go"));
}

void TestRunLog::movesAFullFileAsideAndKeepsTheAnnouncedPath()
{
    QTemporaryDir dir;
    RunLog log;
    QVERIFY(log.open(dir.path(), QStringLiteral("chat_ui")));
    const QString announced = log.path();

    writeLines(log, RunLog::kRotateAfterLines);

    QCOMPARE(log.path(), announced);
    const QStringList names = namesIn(dir.path());
    QCOMPARE(names.size(), 2);
    QVERIFY2(names.at(0).endsWith(QStringLiteral(".001.log")), qPrintable(names.at(0)));
    QCOMPARE(QFileInfo(announced).size(), 0);
    // Both files are the one run, which is what makes a rotation invisible to a
    // reader who only wanted this launch.
    const QList<SessionLogRun> runs = listSessionLogRuns(announced);
    QCOMPARE(runs.size(), 1);
    QCOMPARE(runs.first().paths.size(), 2);
}

void TestRunLog::prunesToTheNewestRunsAndLeavesAnotherWritersAlone()
{
    QTemporaryDir dir;
    for (int day = 1; day <= RunLog::kKeepRuns + 2; ++day)
        placeRun(dir.path(), QStringLiteral("chat_ui"), QStringLiteral("202001%1_120000").arg(day, 2, 10, QLatin1Char('0')));
    // The chat module's own log, in the directory this writer borrows.
    placeRun(dir.path(), QStringLiteral("chat_module"), QStringLiteral("20200101_120000"));

    RunLog log;
    QVERIFY(log.open(dir.path(), QStringLiteral("chat_ui")));

    const QStringList names = namesIn(dir.path());
    // The runs kept are this writer's newest, the run just opened included, and
    // the other writer's file is not this one's to delete.
    QCOMPARE(names.size(), RunLog::kKeepRuns + 1);
    QVERIFY(names.contains(QStringLiteral("chat_module_20200101_120000.log")));
    QVERIFY(!names.contains(QStringLiteral("chat_ui_20200101_120000.log")));
    QVERIFY(!names.contains(QStringLiteral("chat_ui_20200102_120000.log")));
    QVERIFY(names.contains(QStringLiteral("chat_ui_20200112_120000.log")));
}

QTEST_MAIN(TestRunLog)
#include "tst_runlog.moc"
