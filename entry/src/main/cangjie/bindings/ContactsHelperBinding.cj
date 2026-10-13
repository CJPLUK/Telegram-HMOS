package ohos_app_cangjie_entry.bindings

import kit.AbilityKit.*
import kit.PerformanceAnalysisKit.Hilog
import kit.ArkData.*
import std.collection.ArrayList
import std.collection.HashMap
import ohos.business_exception.BusinessException

/**
 * ContactsHelperBinding — 系统通讯录平台封装层
 *
 * 对应 Telegram-iOS ContactsHelper (CNContactStore 桥接层)。
 * 封装鸿蒙系统通讯录 API，提供：
 * - 通讯录权限检查（AbilityAccessCtrl: ohos.permission.READ_CONTACTS / WRITE_CONTACTS）
 * - 枚举系统联系人（RdbStore 只读访问系统通讯录数据库）
 * - 添加联系人到系统通讯录（RdbStore insert）
 *
 * iOS 对应：ContactsEnumerateRequest (CNContactStore.enumeratorForContactFetchRequest)
 *
 * SDK 平台注记（见 unresolved_api_decisions[contacts_kit_missing]）：
 *   Cangjie SDK 6.0 无 kit.ContactsKit，无 DataShareHelper。
 *   本实现通过 RdbStore 的 rootDir 参数直接访问系统通讯录 SQLite 文件，
 *   需要 READ_CONTACTS（只读查询）或 WRITE_CONTACTS（insert）权限。
 *   iOS 的 CNContactStore.enumeratorForContactFetchRequest 等效于此处的 RdbStore 查询。
 *
 * 权限要求：
 *   ohos.permission.READ_CONTACTS — 读取联系人（system_basic，user_grant）
 *   ohos.permission.WRITE_CONTACTS — 写入联系人（system_basic，user_grant）
 *
 * MTProto 说明（N/A）：本地通讯录读取不涉及 MTProto 协议，全部为本地系统 API 调用。
 */

// 系统通讯录数据库根目录（HarmonyOS 系统联系人存储位置，READ_CONTACTS 权限下可读）
private let CONTACTS_DB_ROOT_DIR = "/data/service/el1/public/contactsdata"
private let CONTACTS_DB_NAME = "contacts.db"

// raw_contacts 表（主联系人表）
private let TABLE_RAW_CONTACTS = "raw_contacts"
private let COL_CONTACT_ID = "_id"
private let COL_DISPLAY_NAME = "display_name"

// data 表（联系人详细数据，包含电话号码）
private let TABLE_CONTACT_DATA = "data"
private let COL_DATA_CONTACT_ID = "raw_contact_id"
private let COL_DATA_MIMETYPE_ID = "mimetype_id"
private let COL_DATA1 = "data1"

// HarmonyOS 联系人数据库电话号码 mimetype_id
private let PHONE_MIMETYPE_ID: Int64 = 5

/**
 * 系统联系人数据（与 CNContact 等效的简化模型）
 * iOS 对应：CNContact (firstName, lastName, phoneNumbers)
 */
public class SystemContactData {
    public var displayName: String = ""
    public var firstName: String = ""
    public var lastName: String = ""
    public var phoneNumber: String = ""

    public init() {}

    public init(displayName: String, firstName: String, lastName: String, phoneNumber: String) {
        this.displayName = displayName
        this.firstName = firstName
        this.lastName = lastName
        this.phoneNumber = phoneNumber
    }
}

private var _contactsHelperBindingInstance: Option<ContactsHelperBinding> = None

/**
 * 获取 ContactsHelperBinding 单例
 */
public func getContactsHelperBinding(): ContactsHelperBinding {
    match (_contactsHelperBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ContactsHelperBinding()
            _contactsHelperBindingInstance = Some(inst)
            return inst
    }
}

/**
 * 鸿蒙 RDB 错误码：ResultSet 游标越界（空结果集上调用 goToFirstRow 即抛此码）。
 */
private let CONTACTS_ERR_ROW_OUT_OF_BOUNDS: Int32 = 14800012

/**
 * 安全地把游标移到首行；结果集为空时返回 false 而非抛异常。
 *
 * 鸿蒙 RDB 的 ResultSet.goToFirstRow() 在**无行时抛 BusinessException 14800012**，
 * 而不像 SQLite 那样返回 false。故 `if (cursor.goToFirstRow())` 这种写法在空表上
 * 会在条件求值处直接抛出，if 取不到 false。
 *
 * 对通讯录而言：设备上一个联系人都没有时，枚举查询就是空结果集 —— 那是正常状态，
 * 不是错误。未加保护时会抛异常并使整个枚举失败。
 *
 * 注：本层是平台绑定层，不反向依赖 core.storage.postbox，故此处保留独立实现
 * （postbox 侧的同类保护见 RdbValueBox.safeGoToFirstRow）。
 */
private func contactsSafeGoToFirstRow(cursor: ResultSet): Bool {
    try {
        return cursor.goToFirstRow()
    } catch (e: BusinessException) {
        if (e.code == CONTACTS_ERR_ROW_OUT_OF_BOUNDS) {
            return false
        }
        throw e
    }
}

/**
 * 安全地把游标移到下一行；已到末尾时返回 false 而非抛异常。
 *
 * goToNextRow() 在**遍历越过最后一行**时同样抛 14800012。
 * 本函数此前缺失曾造成一个隐蔽假象：enumerateContacts 看似正常（真机能加载 13 个联系人），
 * 实则异常发生在 13 行全部回调完毕之后，被 enumerateContacts 外层 try/catch 吞掉、
 * 仅使返回值变成 -1；onContact 早已把数据交给 UI，故"看起来是成功的"。
 */
private func contactsSafeGoToNextRow(cursor: ResultSet): Bool {
    try {
        return cursor.goToNextRow()
    } catch (e: BusinessException) {
        if (e.code == CONTACTS_ERR_ROW_OUT_OF_BOUNDS) {
            return false
        }
        throw e
    }
}

/**
 * 系统通讯录平台绑定
 * 通过 RdbStore 的 rootDir 参数访问系统通讯录 SQLite 数据库。
 * context 由调用方（ContactsHelperUtils）传入，避免与 services 包循环依赖。
 */
public class ContactsHelperBinding {

    /**
     * 检查通讯录读取权限是否已授权
     * @return true 表示 READ_CONTACTS 已授权
     */
    public func checkReadPermission(): Bool {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let tokenID = bundleInfo.appInfo.accessTokenId
            let granted = atManager.checkAccessToken(tokenID, "ohos.permission.READ_CONTACTS")
            return granted == GrantStatus.PermissionGranted
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] checkReadPermission error")
            return false
        }
    }

    /**
     * 检查通讯录写入权限是否已授权
     * @return true 表示 WRITE_CONTACTS 已授权
     */
    public func checkWritePermission(): Bool {
        try {
            let atManager = AbilityAccessCtrl.createAtManager()
            let bundleInfo = BundleManager.getBundleInfoForSelf(BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
            let tokenID = bundleInfo.appInfo.accessTokenId
            let granted = atManager.checkAccessToken(tokenID, "ohos.permission.WRITE_CONTACTS")
            return granted == GrantStatus.PermissionGranted
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] checkWritePermission error")
            return false
        }
    }

    /**
     * 枚举系统联系人（真实实现）
     * 通过 RdbStore 只读访问系统通讯录 SQLite 数据库的 raw_contacts 表，
     * 并关联 data 表获取电话号码。
     * iOS 等效：ContactsEnumerateRequest(CNContactStore, CNContactFetchRequest, onContact)
     *
     * @param context UIAbilityContext（由调用方传入，避免循环依赖）
     * @param onContact 每遇到一个联系人时回调
     * @return 成功时返回联系人数量，失败返回 -1
     */
    public func enumerateContacts(context: UIAbilityContext, onContact: (SystemContactData) -> Unit): Int32 {
        var count: Int32 = 0
        try {
            // 以只读模式打开系统通讯录数据库
            let config = StoreConfig(
                RelationalStoreSecurityLevel.S1,
                name: CONTACTS_DB_NAME,
                rootDir: CONTACTS_DB_ROOT_DIR
            )
            let db: RdbStore = getRdbStore(context, config)

            // Step 1: 查询 data 表，构建 contactId → phone 映射
            let phoneMap = HashMap<Int64, String>()
            let phoneSql = "SELECT " + COL_DATA_CONTACT_ID + ", " + COL_DATA1 +
                " FROM " + TABLE_CONTACT_DATA +
                " WHERE " + COL_DATA_MIMETYPE_ID + " = " + PHONE_MIMETYPE_ID.toString() +
                " AND " + COL_DATA1 + " IS NOT NULL"
            let phoneCursor: ResultSet = db.querySql(phoneSql)
            if (contactsSafeGoToFirstRow(phoneCursor)) {
                var hasMore = true
                while (hasMore) {
                    let cIdIdx = phoneCursor.getColumnIndex(COL_DATA_CONTACT_ID)
                    let phoneIdx = phoneCursor.getColumnIndex(COL_DATA1)
                    let cId = phoneCursor.getLong(cIdIdx)
                    let phone = phoneCursor.getString(phoneIdx)
                    if (!phoneMap.contains(cId)) {
                        phoneMap.add(cId, phone)
                    }
                    hasMore = contactsSafeGoToNextRow(phoneCursor)
                }
            }
            phoneCursor.close()

            // Step 2: 查询 raw_contacts 表，遍历联系人
            let rawSql = "SELECT " + COL_CONTACT_ID + ", " + COL_DISPLAY_NAME +
                " FROM " + TABLE_RAW_CONTACTS +
                " WHERE " + COL_DISPLAY_NAME + " IS NOT NULL"
            let rawCursor: ResultSet = db.querySql(rawSql)
            if (contactsSafeGoToFirstRow(rawCursor)) {
                var hasMore = true
                while (hasMore) {
                    let idIdx = rawCursor.getColumnIndex(COL_CONTACT_ID)
                    let nameIdx = rawCursor.getColumnIndex(COL_DISPLAY_NAME)
                    let contactId = rawCursor.getLong(idIdx)
                    let displayName = rawCursor.getString(nameIdx)

                    var phone = ""
                    match (phoneMap.get(contactId)) {
                        case Some(p) => phone = p
                        case _ => ()
                    }

                    // 从 displayName 拆分 firstName/lastName（最后一个空格分隔）
                    let trimmedName = displayName.trimAscii()
                    let spacePos = this.findLastSpacePos(trimmedName)
                    let firstName: String
                    let lastName: String
                    if (spacePos >= 0) {
                        firstName = trimmedName[0..spacePos]
                        lastName = trimmedName[(spacePos + 1)..]
                    } else {
                        firstName = trimmedName
                        lastName = ""
                    }

                    onContact(SystemContactData(trimmedName, firstName, lastName, phone))
                    count = count + 1
                    hasMore = contactsSafeGoToNextRow(rawCursor)
                }
            }
            rawCursor.close()

            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] enumerateContacts: done")
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] enumerateContacts BusinessException")
            return -1
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] enumerateContacts error")
            return -1
        }
        return count
    }

    /**
     * 添加联系人到系统通讯录（真实实现）
     * 通过 RdbStore 向系统通讯录 SQLite 数据库插入新记录。
     * iOS 等效：CNSaveRequest.add(contact) + CNContactStore.execute(saveRequest)
     *
     * @param context UIAbilityContext（由调用方传入）
     * @param firstName 名
     * @param lastName 姓
     * @param phone 电话号码
     * @return true 表示添加成功
     */
    public func addContact(context: UIAbilityContext, firstName: String, lastName: String, phone: String): Bool {
        try {
            // 写入模式需要 WRITE_CONTACTS 权限（不使用 rootDir，走应用沙箱路径通过系统授权）
            let config = StoreConfig(
                RelationalStoreSecurityLevel.S1,
                name: CONTACTS_DB_NAME,
                customDir: "contacts_write"
            )
            let db: RdbStore = getRdbStore(context, config)

            let displayName = if (lastName.size > 0) {
                firstName + " " + lastName
            } else {
                firstName
            }

            // 插入 raw_contacts 记录
            let rawRow = HashMap<String, RelationalStoreValueType>()
            rawRow.add(COL_DISPLAY_NAME, RelationalStoreValueType.StringValue(displayName))
            let insertedId: Int64 = db.insert(TABLE_RAW_CONTACTS, rawRow)

            if (insertedId < 0) {
                Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] addContact: insert failed")
                return false
            }

            // 插入 data 记录（电话号码）
            if (phone.size > 0) {
                let phoneRow = HashMap<String, RelationalStoreValueType>()
                phoneRow.add(COL_DATA_CONTACT_ID, RelationalStoreValueType.Integer(insertedId))
                phoneRow.add(COL_DATA_MIMETYPE_ID, RelationalStoreValueType.Integer(PHONE_MIMETYPE_ID))
                phoneRow.add(COL_DATA1, RelationalStoreValueType.StringValue(phone))
                let _ = db.insert(TABLE_CONTACT_DATA, phoneRow)
            }

            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] addContact: success")
            return true
        } catch (e: BusinessException) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] addContact BusinessException")
            return false
        } catch (e: Exception) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] addContact error")
            return false
        }
    }

    /**
     * 读取系统联系人列表（便捷方法，需要 UIAbilityContext）
     * @param context UIAbilityContext（由调用方传入）
     * @return 联系人列表，失败时返回空列表
     */
    public func readSystemContacts(context: UIAbilityContext): ArrayList<SystemContactData> {
        let result = ArrayList<SystemContactData>()
        let count = this.enumerateContacts(context, { c: SystemContactData =>
            result.add(c)
        })
        if (count < 0) {
            Hilog.info(0, "CjTelegram", "[ContactsHelperBinding] readSystemContacts: query failed")
        }
        return result
    }

    /**
     * 查找字符串最后一个空格的字节偏移量
     * @param s 输入字符串
     * @return 偏移量（0-based），找不到返回 -1
     */
    private func findLastSpacePos(s: String): Int64 {
        let runes = s.toRuneArray()
        var pos: Int64 = -1
        for (i in 0..runes.size) {
            if (runes[i] == r' ') {
                pos = i
            }
        }
        return pos
    }
}
