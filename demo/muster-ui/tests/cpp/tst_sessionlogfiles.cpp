#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QTest>

#include "SessionLogFiles.h"

class TestSessionLogFiles : public QObject
{
    Q_OBJECT

private slots:
    void noPathHasNoRuns();
    void groupsRotationsIntoOneRun();
    void ordersRunsNewestFirst();
    void ignoresOtherFiles();
    void separatesTwoWritersSharingOneDirectory();
    void reportsAnUnstampedPathOnItsOwn();

private:
    // Writes `bytes` bytes into <dir>/<name>, so a run has a size to report.
    static void write(const QTemporaryDir& dir, const QString& name, int bytes);
};

void TestSessionLogFiles::write(const QTemporaryDir& dir, const QString& name, int bytes)
{
    QFile file(dir.filePath(name));
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(QByteArray(bytes, 'x'));
}

void TestSessionLogFiles::noPathHasNoRuns()
{
    QVERIFY(listSessionLogRuns(QString()).isEmpty());
}

void TestSessionLogFiles::groupsRotationsIntoOneRun()
{
    QTemporaryDir dir;
    write(dir, QStringLiteral("basecamp_20260728_100000.001.log"), 10);
    write(dir, QStringLiteral("basecamp_20260728_100000.002.log"), 20);
    write(dir, QStringLiteral("basecamp_20260728_100000.log"), 5);

    const QList<SessionLogRun> runs =
        listSessionLogRuns(dir.filePath(QStringLiteral("basecamp_20260728_100000.log")));

    QCOMPARE(runs.size(), 1);
    QCOMPARE(runs.first().bytes, 35);
    QCOMPARE(runs.first().stamp, QStringLiteral("20260728_100000"));
    // Oldest rotation first, the file still being written last: reading them in
    // that order reads the run in the order it happened.
    QCOMPARE(runs.first().paths.size(), 3);
    QVERIFY(runs.first().paths.at(0).endsWith(QStringLiteral(".001.log")));
    QVERIFY(runs.first().paths.at(1).endsWith(QStringLiteral(".002.log")));
    QVERIFY(runs.first().paths.at(2).endsWith(QStringLiteral("100000.log")));
}

void TestSessionLogFiles::ordersRunsNewestFirst()
{
    QTemporaryDir dir;
    write(dir, QStringLiteral("basecamp_20260726_080000.log"), 1);
    write(dir, QStringLiteral("basecamp_20260728_100000.log"), 1);
    write(dir, QStringLiteral("basecamp_20260727_090000.log"), 1);

    const QList<SessionLogRun> runs =
        listSessionLogRuns(dir.filePath(QStringLiteral("basecamp_20260728_100000.log")));

    QCOMPARE(runs.size(), 3);
    QCOMPARE(runs.at(0).stamp, QStringLiteral("20260728_100000"));
    QCOMPARE(runs.at(1).stamp, QStringLiteral("20260727_090000"));
    QCOMPARE(runs.at(2).stamp, QStringLiteral("20260726_080000"));
}

void TestSessionLogFiles::ignoresOtherFiles()
{
    QTemporaryDir dir;
    write(dir, QStringLiteral("basecamp_20260728_100000.log"), 1);
    // Another app logging into the same directory, and a file that only looks
    // like a run.
    write(dir, QStringLiteral("logos-standalone-app_20260728_100000.log"), 1);
    write(dir, QStringLiteral("basecamp_notastamp.log"), 1);
    write(dir, QStringLiteral("basecamp_20260728_100000.log.bak"), 1);

    const QList<SessionLogRun> runs =
        listSessionLogRuns(dir.filePath(QStringLiteral("basecamp_20260728_100000.log")));

    QCOMPARE(runs.size(), 1);
    QCOMPARE(runs.first().paths.size(), 1);
}

// This view keeps its log in the chat module's instance directory, for want of
// one of its own, so one directory holds two writers' runs. The whole
// arrangement rests on each list being its own writer's and no one else's.
void TestSessionLogFiles::separatesTwoWritersSharingOneDirectory()
{
    QTemporaryDir dir;
    write(dir, QStringLiteral("chat_ui_20260728_100000.log"), 1);
    write(dir, QStringLiteral("chat_ui_20260727_090000.log"), 1);
    write(dir, QStringLiteral("chat_module_20260728_100000.log"), 1);
    write(dir, QStringLiteral("chat_module_20260728_100000.001.log"), 1);
    write(dir, QStringLiteral("chat_module_20260726_080000.log"), 1);

    const QList<SessionLogRun> view =
        listSessionLogRuns(dir.filePath(QStringLiteral("chat_ui_20260728_100000.log")));
    const QList<SessionLogRun> core =
        listSessionLogRuns(dir.filePath(QStringLiteral("chat_module_20260728_100000.log")));

    QCOMPARE(view.size(), 2);
    QCOMPARE(view.at(0).paths.size(), 1);
    QCOMPARE(core.size(), 2);
    // The module's newest run rotated once; the view's file of the same stamp is
    // not part of it.
    QCOMPARE(core.at(0).paths.size(), 2);
    for (const SessionLogRun& run : view) {
        for (const QString& path : run.paths)
            QVERIFY2(path.contains(QStringLiteral("chat_ui_")), qPrintable(path));
    }
    for (const SessionLogRun& run : core) {
        for (const QString& path : run.paths)
            QVERIFY2(path.contains(QStringLiteral("chat_module_")), qPrintable(path));
    }
}

void TestSessionLogFiles::reportsAnUnstampedPathOnItsOwn()
{
    QTemporaryDir dir;
    write(dir, QStringLiteral("session.log"), 7);

    const QList<SessionLogRun> runs = listSessionLogRuns(dir.filePath(QStringLiteral("session.log")));

    QCOMPARE(runs.size(), 1);
    QCOMPARE(runs.first().paths.size(), 1);
    QCOMPARE(runs.first().bytes, 7);
    QVERIFY(runs.first().stamp.isEmpty());
}

QTEST_MAIN(TestSessionLogFiles)
#include "tst_sessionlogfiles.moc"
