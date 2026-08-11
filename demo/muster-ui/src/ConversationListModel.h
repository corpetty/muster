#ifndef CONVERSATION_LIST_MODEL_H
#define CONVERSATION_LIST_MODEL_H

#include <QAbstractListModel>
#include <QDateTime>
#include <QHash>
#include <QString>
#include <QVector>

struct ConversationItem {
    QString conversationId;
    QString displayName;
    QString description;
    QDateTime lastActivity;
    int unreadCount = 0;
    bool isGroup = false;
    // Truncated last-message content shown as a list preview.
    QString preview;
};

class ConversationListModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        ConversationIdRole = Qt::UserRole + 1,
        DisplayNameRole,
        LastActivityRole,
        UnreadCountRole,
        IsGroupRole,
        // Relative last-activity label ("14:03" today, "Yesterday", else a short
        // date). Computed when the activity changes, so an app left idle keeps
        // yesterday's label until the next activity or a rehydrate; there is no
        // day-tick timer.
        LastActivityDisplayRole,
        // Truncated last-message content for the list preview.
        PreviewRole,
        DescriptionRole,
        // Avatar identity, derived from the conversation id rather than the
        // display name: a direct conversation's name is generated from that id
        // too, and a group's avatar carries a glyph instead of initials.
        AvatarInitialsRole,
        AvatarRampRole
    };

    explicit ConversationListModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void addConversation(const QString& id, const QString& displayName,
                         const QString& description, const QDateTime& lastActivity, bool isGroup,
                         const QString& preview);
    void updateDisplayName(const QString& id, const QString& displayName);
    void updateDescription(const QString& id, const QString& description);
    void updatePreview(const QString& id, const QString& preview);
    void updateLastActivity(const QString& id, const QDateTime& lastActivity);
    void incrementUnread(const QString& id);
    void clearUnread(const QString& id);
    // Unread counts by conversation id, and their restoration onto a rebuilt
    // list: the module does not track them, so a rebuild would drop them.
    QHash<QString, int> unreadCounts() const;
    void restoreUnreadCounts(const QHash<QString, int>& counts);
    void removeConversation(const QString& id);
    void clear();
    bool contains(const QString& id) const;

    int indexOf(const QString& id) const;

    // Display name for a conversation id, or empty if unknown.
    Q_INVOKABLE QString displayNameFor(const QString& id) const;

    // Group description for a conversation id, or empty if unknown or unset.
    Q_INVOKABLE QString descriptionFor(const QString& id) const;

    // Whether a conversation is a group; false for a direct or unknown id.
    Q_INVOKABLE bool isGroupFor(const QString& id) const;

private:
    // Relative label for the last-activity timestamp (see LastActivityDisplayRole).
    QString formatLastActivity(const QDateTime& lastActivity) const;

    QVector<ConversationItem> m_items;
};

#endif
