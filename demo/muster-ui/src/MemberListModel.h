#ifndef MEMBER_LIST_MODEL_H
#define MEMBER_LIST_MODEL_H

#include <QAbstractListModel>
#include <QString>
#include <QVector>

struct MemberItem {
    // The member's verified account address, empty when no account is confirmed
    // — used for the tooltip and identity comparisons.
    QString address;
    // True for this installation's own entry in the roster.
    bool isSelf = false;
    // A member invited but not yet committed into the group.
    bool pending = false;
};

// A group's roster, replaced wholesale on each refresh. `label` is the short
// form of `address` (or "unknown_account" when the address is empty), computed
// here so QML renders a consistent identity string.
class MemberListModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles {
        AddressRole = Qt::UserRole + 1,
        LabelRole,
        IsSelfRole,
        PendingRole,
        // Avatar identity, derived from the address so one account keeps one
        // pair of initials and one colour wherever it is drawn.
        AvatarInitialsRole,
        AvatarRampRole
    };

    explicit MemberListModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setMembers(const QVector<MemberItem>& members);
    void clear();
    // True when `address` is a committed member. A pending invite does not
    // count: it cannot take part in the conversation until the group commits it.
    bool contains(const QString& address) const;

private:
    QVector<MemberItem> m_items;
};

#endif
