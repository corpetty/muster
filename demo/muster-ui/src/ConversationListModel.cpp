#include "ConversationListModel.h"

#include "Identity.h"
#include "TimeFormat.h"

#include <QDate>
#include <QLocale>

ConversationListModel::ConversationListModel(QObject* parent)
    : QAbstractListModel(parent)
{
}

int ConversationListModel::rowCount(const QModelIndex& parent) const
{
    if (parent.isValid()) return 0;
    return m_items.size();
}

QVariant ConversationListModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};

    const auto& item = m_items.at(index.row());
    switch (role) {
    case ConversationIdRole:      return item.conversationId;
    case DisplayNameRole:         return item.displayName;
    case LastActivityRole:        return item.lastActivity;
    case LastActivityDisplayRole: return formatLastActivity(item.lastActivity);
    case UnreadCountRole:         return item.unreadCount;
    case IsGroupRole:             return item.isGroup;
    case PreviewRole:             return item.preview;
    case DescriptionRole:         return item.description;
    case AvatarInitialsRole:      return Identity::initials(item.conversationId);
    case AvatarRampRole:          return Identity::avatarRamp(Identity::shortLabel(item.conversationId));
    default:                      return {};
    }
}

QHash<int, QByteArray> ConversationListModel::roleNames() const
{
    return {
        { ConversationIdRole,      "conversationId" },
        { DisplayNameRole,         "displayName" },
        { LastActivityRole,        "lastActivity" },
        { LastActivityDisplayRole, "lastActivityDisplay" },
        { UnreadCountRole,         "unreadCount" },
        { IsGroupRole,             "isGroup" },
        { PreviewRole,             "preview" },
        { DescriptionRole,         "description" },
        { AvatarInitialsRole,      "avatarInitials" },
        { AvatarRampRole,          "avatarRamp" }
    };
}

void ConversationListModel::addConversation(const QString& id, const QString& displayName,
                                            const QString& description, const QDateTime& lastActivity,
                                            bool isGroup, const QString& preview)
{
    if (contains(id)) return;

    beginInsertRows(QModelIndex(), m_items.size(), m_items.size());
    m_items.append({ id, displayName, description, lastActivity, 0, isGroup, preview });
    endInsertRows();
}

void ConversationListModel::updateDisplayName(const QString& id, const QString& displayName)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    if (m_items[idx].displayName == displayName) return;
    m_items[idx].displayName = displayName;
    emit dataChanged(index(idx), index(idx), { DisplayNameRole });
}

void ConversationListModel::updateDescription(const QString& id, const QString& description)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    if (m_items[idx].description == description) return;
    m_items[idx].description = description;
    emit dataChanged(index(idx), index(idx), { DescriptionRole });
}

void ConversationListModel::updatePreview(const QString& id, const QString& preview)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    if (m_items[idx].preview == preview) return;
    m_items[idx].preview = preview;
    emit dataChanged(index(idx), index(idx), { PreviewRole });
}

void ConversationListModel::updateLastActivity(const QString& id, const QDateTime& lastActivity)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    m_items[idx].lastActivity = lastActivity;
    emit dataChanged(index(idx), index(idx), { LastActivityRole, LastActivityDisplayRole });
}

void ConversationListModel::incrementUnread(const QString& id)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    m_items[idx].unreadCount++;
    emit dataChanged(index(idx), index(idx), { UnreadCountRole });
}

void ConversationListModel::clearUnread(const QString& id)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    if (m_items[idx].unreadCount == 0) return;
    m_items[idx].unreadCount = 0;
    emit dataChanged(index(idx), index(idx), { UnreadCountRole });
}

QHash<QString, int> ConversationListModel::unreadCounts() const
{
    QHash<QString, int> counts;
    for (const auto& item : m_items) {
        if (item.unreadCount > 0)
            counts.insert(item.conversationId, item.unreadCount);
    }
    return counts;
}

void ConversationListModel::restoreUnreadCounts(const QHash<QString, int>& counts)
{
    for (int i = 0; i < m_items.size(); ++i) {
        const int count = counts.value(m_items.at(i).conversationId, 0);
        if (count == 0 || m_items[i].unreadCount == count) continue;
        m_items[i].unreadCount = count;
        emit dataChanged(index(i), index(i), { UnreadCountRole });
    }
}

void ConversationListModel::removeConversation(const QString& id)
{
    int idx = indexOf(id);
    if (idx < 0) return;

    beginRemoveRows(QModelIndex(), idx, idx);
    m_items.removeAt(idx);
    endRemoveRows();
}

void ConversationListModel::clear()
{
    if (m_items.isEmpty()) return;
    beginResetModel();
    m_items.clear();
    endResetModel();
}

bool ConversationListModel::contains(const QString& id) const
{
    return indexOf(id) >= 0;
}

int ConversationListModel::indexOf(const QString& id) const
{
    for (int i = 0; i < m_items.size(); ++i) {
        if (m_items[i].conversationId == id)
            return i;
    }
    return -1;
}

QString ConversationListModel::displayNameFor(const QString& id) const
{
    const int idx = indexOf(id);
    return idx < 0 ? QString() : m_items.at(idx).displayName;
}

QString ConversationListModel::descriptionFor(const QString& id) const
{
    const int idx = indexOf(id);
    return idx < 0 ? QString() : m_items.at(idx).description;
}

bool ConversationListModel::isGroupFor(const QString& id) const
{
    const int idx = indexOf(id);
    return idx >= 0 && m_items.at(idx).isGroup;
}

QString ConversationListModel::formatLastActivity(const QDateTime& lastActivity) const
{
    if (!lastActivity.isValid())
        return {};

    const QLocale locale = QLocale::system();
    const QDate today = QDate::currentDate();
    const QDate date = lastActivity.date();
    if (date == today)
        return TimeFormat::shortTime(lastActivity);
    if (date == today.addDays(-1))
        return tr("Yesterday");
    return locale.toString(date, QLocale::ShortFormat);
}
