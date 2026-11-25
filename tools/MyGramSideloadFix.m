#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@implementation NSFileManager (MyGramSideloadFix)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [NSFileManager class];
        SEL origSel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        SEL swizSel = @selector(mygram_containerURLForSecurityApplicationGroupIdentifier:);
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method swizMethod = class_getInstanceMethod(cls, swizSel);
        if (origMethod && swizMethod) {
            method_exchangeImplementations(origMethod, swizMethod);
        }
    });
}

- (nullable NSURL *)mygram_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    NSURL *url = [self mygram_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    if (url != nil) {
        return url;
    }
    if (groupIdentifier.length == 0) {
        return nil;
    }
    NSURL *docs = [[self URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    if (docs == nil) {
        return nil;
    }
    NSURL *fakeGroup = [[docs URLByAppendingPathComponent:@"FakeGroupContainers" isDirectory:YES]
                        URLByAppendingPathComponent:groupIdentifier isDirectory:YES];
    [self createDirectoryAtURL:fakeGroup withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *caches = [[fakeGroup URLByAppendingPathComponent:@"Library" isDirectory:YES]
                     URLByAppendingPathComponent:@"Caches" isDirectory:YES];
    [self createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
    return fakeGroup;
}

@end
