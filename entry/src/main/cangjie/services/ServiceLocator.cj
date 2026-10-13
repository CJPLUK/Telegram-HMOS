package ohos_app_cangjie_entry.services

import kit.PerformanceAnalysisKit.Hilog

/**
 * 服务定位器（Phase G3）
 * 
 * 参照 TelegramHarmony 的依赖注入模式
 * 
 * 集中管理所有服务实例的创建和获取
 * 支持 Real 和 Mock 模式切换
 */

public enum ServiceMode {
    | Real
    | Mock
}

private var _serviceLocatorInstance: Option<ServiceLocator> = None

public func getServiceLocator(): ServiceLocator {
    match (_serviceLocatorInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = ServiceLocator()
            _serviceLocatorInstance = Some(inst)
            return inst
    }
}

public class ServiceLocator {
    private var mode: ServiceMode = ServiceMode.Real
    
    /**
     * 设置服务模式（Real / Mock）
     * 在应用启动时调用，决定使用真实服务还是 Mock 服务
     */
    public func setMode(mode: ServiceMode) {
        this.mode = mode
        let modeStr = match (this.mode) {
            case Real => "Real"
            case Mock => "Mock"
        }
        Hilog.info(0, "CjTelegram", "[ServiceLocator] Mode set to: ${modeStr}")
    }
    
    /**
     * 获取当前模式
     */
    public func getMode(): ServiceMode {
        return this.mode
    }
    
    /**
     * 检查是否为真实模式
     */
    public func isRealMode(): Bool {
        return match (this.mode) {
            case Real => true
            case Mock => false
        }
    }
    
    /**
     * 获取认证服务
     */
    public func getAuthService(): RealAuthService {
        return getRealAuthService()
    }
    
    /**
     * 获取聊天列表服务
     */
    public func getChatListService(): RealChatListService {
        return getRealChatListService()
    }
    
    /**
     * 获取消息服务
     */
    public func getMessageService(): RealMessageService {
        return getRealMessageService()
    }
    
    /**
     * 获取联系人服务
     */
    public func getContactService(): RealContactService {
        return getRealContactService()
    }
    
    /**
     * 重置所有服务（登出时调用）
     */
    public func resetAllServices() {
        Hilog.info(0, "CjTelegram", "[ServiceLocator] Resetting all services")
    }
}
