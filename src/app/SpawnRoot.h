/*
 * SpawnRoot.h - TrollStore 提权进程启动头文件
 */

#import <Foundation/Foundation.h>

@interface SpawnRoot : NSObject

/* 依据 TrollStore TSUtil.m 的 persona 规范启动 root helper */
+ (int)spawnHelperBinary:(NSString *)binaryPath
                     pid:(pid_t *)outPid
                  errNum:(int *)outErrno
                  errMsg:(NSString **)outErrMsg;

/* 依据 TrollStore persona 规范带参数启动 root helper */
+ (int)spawnHelperBinary:(NSString *)binaryPath
                    args:(NSArray<NSString *> *)arguments
             environment:(NSDictionary<NSString *, NSString *> *)environment
                    root:(BOOL)root
                 logPath:(NSString *)logPath
                     pid:(pid_t *)outPid
                  errNum:(int *)outErrno
                  errMsg:(NSString **)outErrMsg;

/* 修改目标文件权限为全局可访问 */
+ (int)chmodPath:(NSString *)path mode:(mode_t)mode;

/* 通过原生 BSD sysctl 与 kill 系统调用精准清理残留进程并清除 socket 节点 */
+ (int)terminateDaemonNamed:(NSString *)processName socketPath:(NSString *)sockPath;

/* 仅终止并回收本 App 启动的子进程 */
+ (int)terminateChild:(pid_t)pid;

/* 非阻塞回收自有子进程；运行中返回 -EAGAIN，错误返回负 errno */
+ (int)pollChild:(pid_t)pid;

@end
