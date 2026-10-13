export declare interface CustomLib {
    registerArkFunc(name: string, fn: (funcArg0: string, funcArg1: (funcArgfuncArg0: string) => void) => void): void
    dispatchEvent(event: string, payloadJson: string): void
}