/* HBQueueController

    This file is part of the HandBrake source code.
    Homepage: <http://handbrake.fr/>.
    It may be used under the terms of the GNU General Public License. */

#import "HBQueueController.h"

#import "HBQueueItem.h"

#import "HBController.h"
#import "HBAppDelegate.h"

#import "HBTableView.h"
#import "HBQueueItemView.h"

#import "NSArray+HBAdditions.h"
#import "HBUtilities.h"

#import "HBDockTile.h"

#import "HBOutputRedirect.h"
#import "HBJobOutputFileWriter.h"
#import "HBPreferencesController.h"

@import HandBrakeKit;

// Pasteboard type for or drag operations
#define DragDropSimplePboardType    @"HBQueueCustomTableViewPboardType"

// DockTile update frequency in total percent increment
#define dockTileUpdateFrequency     0.1f

static void *HBControllerQueueCoreContext = &HBControllerQueueCoreContext;

@interface HBQueueController () <NSTableViewDataSource, HBTableViewDelegate, HBQueueItemViewDelegate, NSUserNotificationCenterDelegate>

/// Whether the window is visible or occluded,
/// useful to avoid updating the UI needlessly
@property (nonatomic) BOOL visible;

// Progress
@property (nonatomic, strong) NSAttributedString *progressInfo;
@property (nonatomic, strong) NSDictionary *monospacedAttr;

@property (nonatomic, readonly) HBDockTile *dockTile;
@property (nonatomic, readwrite) double dockIconProgress;

@property (unsafe_unretained) IBOutlet NSTextField *progressTextField;
@property (unsafe_unretained) IBOutlet NSTextField *countTextField;
@property (unsafe_unretained) IBOutlet HBTableView *tableView;

@property (nonatomic) IBOutlet NSToolbarItem *ripToolbarItem;
@property (nonatomic) IBOutlet NSToolbarItem *pauseToolbarItem;

@property (nonatomic) NSTableCellView *dummyCell;
@property (nonatomic) NSLayoutConstraint *dummyCellWidth;

@property (nonatomic, readonly) HBDistributedArray<HBQueueItem *> *items;

@property (nonatomic) HBQueueItem *currentItem;
@property (nonatomic) HBJobOutputFileWriter *currentLog;

@property (nonatomic, readwrite) BOOL stop;

@property (nonatomic, readwrite) NSUInteger pendingItemsCount;
@property (nonatomic, readwrite) NSUInteger completedItemsCount;

@property (nonatomic) NSArray<HBQueueItem *> *dragNodesArray;

@end

@interface HBQueueController (TouchBar) <NSTouchBarProvider, NSTouchBarDelegate>
- (void)_touchBar_updateButtonsStateForQueueCore:(HBState)state;
- (void)_touchBar_validateUserInterfaceItems;
@end

@implementation HBQueueController

- (instancetype)initWithURL:(NSURL *)queueURL;
{
    NSParameterAssert(queueURL);

    if (self = [super initWithWindowNibName:@"Queue"])
    {
        // Load the dockTile and instiante initial text fields
        _dockTile = [[HBDockTile alloc] initWithDockTile:[[NSApplication sharedApplication] dockTile]
                                                  image:[[NSApplication sharedApplication] applicationIconImage]];

        NSInteger loggingLevel = [[NSUserDefaults standardUserDefaults] integerForKey:@"LoggingLevel"];

        // Init a separate instance of libhb for the queue
        _core = [[HBCore alloc] initWithLogLevel:loggingLevel name:@"QueueCore"];
        _core.automaticallyPreventSleep = NO;

        // Progress
        _monospacedAttr = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize] weight:NSFontWeightRegular]};
        _progressInfo = [[NSAttributedString alloc] initWithString:@""];

        // Load the queue from disk.
        _items = [[HBDistributedArray alloc] initWithURL:queueURL class:[HBQueueItem class]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadQueue) name:HBDistributedArrayChanged object:_items];

        [NSUserNotificationCenter defaultUserNotificationCenter].delegate = self;
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)windowDidLoad
{
    if (@available (macOS 10.12, *))
    {
        self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    }

    // lets setup our queue list table view for drag and drop here
    [self.tableView registerForDraggedTypes:@[DragDropSimplePboardType]];
    [self.tableView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
    [self.tableView setVerticalMotionCanBeginDrag:YES];

    [self updateQueueStats];

    [self.core addObserver:self forKeyPath:@"state"
                         options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                         context:HBControllerQueueCoreContext];
    [self addObserver:self forKeyPath:@"pendingItemsCount"
                   options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                   context:HBControllerQueueCoreContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == HBControllerQueueCoreContext)
    {
        HBState state = self.core.state;
        [self updateToolbarButtonsStateForQueueCore:state];
        [self.window.toolbar validateVisibleItems];
        if (@available(macOS 10.12.2, *))
        {
            [self _touchBar_updateButtonsStateForQueueCore:state];
            [self _touchBar_validateUserInterfaceItems];
        }
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark Toolbar

- (void)updateToolbarButtonsStateForQueueCore:(HBState)state
{
    if (state == HBStatePaused)
    {
        _pauseToolbarItem.image = [NSImage imageNamed: @"encode"];
        _pauseToolbarItem.label = NSLocalizedString(@"Resume", @"Toolbar Pause Item");
        _pauseToolbarItem.toolTip = NSLocalizedString(@"Resume Encoding", @"Toolbar Pause Item");
    }
    else
    {
        _pauseToolbarItem.image = [NSImage imageNamed:@"pauseencode"];
        _pauseToolbarItem.label = NSLocalizedString(@"Pause", @"Toolbar Pause Item");
        _pauseToolbarItem.toolTip = NSLocalizedString(@"Pause Encoding", @"Toolbar Pause Item");

    }
    if (state == HBStateScanning || state == HBStateWorking || state == HBStateSearching || state == HBStateMuxing || state == HBStatePaused)
    {
        _ripToolbarItem.image = [NSImage imageNamed:@"stopencode"];
        _ripToolbarItem.label = NSLocalizedString(@"Stop", @"Toolbar Start/Stop Item");
        _ripToolbarItem.toolTip = NSLocalizedString(@"Stop Encoding", @"Toolbar Start/Stop Item");
    }
    else
    {
        _ripToolbarItem.image = [NSImage imageNamed: @"encode"];
        _ripToolbarItem.label = NSLocalizedString(@"Start", @"Toolbar Start/Stop Item");
        _pauseToolbarItem.toolTip = NSLocalizedString(@"Start Encoding", @"Toolbar Start/Stop Item");
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = menuItem.action;

    if (action == @selector(rip:))
    {
        if (self.core.state == HBStateIdle)
        {
            menuItem.title = NSLocalizedString(@"Start Encoding", @"Queue -> start/stop menu");

            return (self.pendingItemsCount > 0);
        }
        else if (self.core.state != HBStateIdle)
        {
            menuItem.title = NSLocalizedString(@"Stop Encoding", @"Queue -> start/stop menu");

            return YES;
        }
    }

    if (action == @selector(pause:))
    {
        if (self.core.state != HBStatePaused)
        {
            menuItem.title = NSLocalizedString(@"Pause Encoding", @"Queue -> pause/resume menu");
        }
        else
        {
            menuItem.title = NSLocalizedString(@"Resume Encoding", @"Queue -> pause/resume men");
        }

        return (self.core.state == HBStateWorking || self.core.state == HBStatePaused);
    }

    if (action == @selector(editSelectedQueueItem:) ||
        action == @selector(removeSelectedQueueItem:) ||
        action == @selector(revealSelectedQueueItems:) ||
        action == @selector(revealSelectedQueueItemsSources:))
    {
        return (self.tableView.selectedRow != -1 || self.tableView.clickedRow != -1);
    }

    if (action == @selector(resetJobState:))
    {
        return self.tableView.targetedRowIndexes.count > 0;
    }

    if (action == @selector(clearAll:))
    {
        return self.items.count > 0;
    }

    if (action == @selector(clearCompleted:))
    {
        return self.completedItemsCount > 0;
    }

    return YES;
}

- (BOOL)validateUserIterfaceItemForAction:(SEL)action
{
    HBState s = self.core.state;

    if (action == @selector(toggleStartCancel:))
    {
        if ((s == HBStateScanning) || (s == HBStatePaused) || (s == HBStateWorking) || (s == HBStateMuxing))
        {
            return YES;
        }
        else
        {
            return (self.pendingItemsCount > 0);
        }
    }

    if (action == @selector(togglePauseResume:))
    {
        if (s == HBStatePaused)
        {
            return YES;
        }
        else
        {
            return (s == HBStateWorking || s == HBStateMuxing);
        }
    }

    return NO;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
    SEL action = theItem.action;
    return [self validateUserIterfaceItemForAction:action];
}

#pragma mark - Public methods

- (void)addJob:(HBJob *)item
{
    NSParameterAssert(item);
    [self addJobsFromArray:@[item]];
}

- (void)addJobsFromArray:(NSArray<HBJob *> *)jobs;
{
    NSParameterAssert(jobs);
    NSMutableArray *itemsToAdd = [NSMutableArray array];
    for (HBJob *job in jobs)
    {
        HBQueueItem *item = [[HBQueueItem alloc] initWithJob:job];
        [itemsToAdd addObject:item];
    }
    if (itemsToAdd.count)
    {
        [self addQueueItems:itemsToAdd];
    }
}

- (BOOL)jobExistAtURL:(NSURL *)url
{
    NSParameterAssert(url);

    for (HBQueueItem *item in self.items)
    {
        if ((item.state == HBQueueItemStateReady || item.state == HBQueueItemStateWorking)
            && [item.completeOutputURL isEqualTo:url])
        {
            return YES;
        }
    }
    return NO;
}

- (NSUInteger)count
{
    return self.items.count;
}

/**
 * This method will clear the queue of any encodes that are not still pending
 * this includes both successfully completed encodes as well as canceled encodes
 */
- (void)removeCompletedJobs
{
    [self.items beginTransaction];
    NSIndexSet *indexes = [self.items indexesOfObjectsUsingBlock:^BOOL(HBQueueItem *item) {
        return (item.state == HBQueueItemStateCompleted || item.state == HBQueueItemStateCanceled);
    }];
    [self removeQueueItemsAtIndexes:indexes];
    [self.items commit];
}

/**
 * This method will clear the queue of all encodes. effectively creating an empty queue
 */
- (void)removeAllJobs
{
    [self.items beginTransaction];
    [self removeQueueItemsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.items.count)]];
    [self.items commit];
}

/**
 * This method will set any item marked as encoding back to pending
 * currently used right after a queue reload
 */
- (void)setEncodingJobsAsPending
{
    [self.items beginTransaction];

    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    NSUInteger idx = 0;
    for (HBQueueItem *item in self.items)
    {
        // We want to keep any queue item that is pending or was previously being encoded
        if (item.state == HBQueueItemStateWorking)
        {
            item.state = HBQueueItemStateReady;
            [indexes addIndex:idx];
        }
        idx++;
    }
    [self reloadQueueItemsAtIndexes:indexes];
    [self.items commit];
}

#pragma mark - Private queue editing methods

/**
 *  Reloads the queue, this is called
 *  when another HandBrake instances modifies the queue
 */
- (void)reloadQueue
{
    [self updateQueueStats];
    [self.tableView reloadData];
    [self.window.undoManager removeAllActions];
}

- (void)reloadQueueItemAtIndex:(NSUInteger)idx
{
    [self reloadQueueItemsAtIndexes:[NSIndexSet indexSetWithIndex:idx]];
}

- (void)reloadQueueItemsAtIndexes:(NSIndexSet *)indexes
{
    NSIndexSet *columnIndexes = [NSIndexSet indexSetWithIndex:0];
    [self.tableView reloadDataForRowIndexes:indexes columnIndexes:columnIndexes];
    [self updateQueueStats];
}

- (void)addQueueItems:(NSArray<HBQueueItem *> *)items
{
    NSParameterAssert(items);
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(self.items.count, items.count)];
    [self addQueueItems:items atIndexes:indexes];
}

- (void)addQueueItems:(NSArray *)items atIndexes:(NSIndexSet *)indexes
{
    NSParameterAssert(items);
    NSParameterAssert(indexes);
    [self.items beginTransaction];
    [self.tableView beginUpdates];

    // Forward
    NSUInteger currentIndex = indexes.firstIndex;
    NSUInteger currentObjectIndex = 0;
    while (currentIndex != NSNotFound)
    {
        [self.items insertObject:items[currentObjectIndex] atIndex:currentIndex];
        currentIndex = [indexes indexGreaterThanIndex:currentIndex];
        currentObjectIndex++;
    }

    [self.tableView insertRowsAtIndexes:indexes
                             withAnimation:NSTableViewAnimationSlideDown];

    NSUndoManager *undo = self.window.undoManager;
    [[undo prepareWithInvocationTarget:self] removeQueueItemsAtIndexes:indexes];

    if (!undo.isUndoing)
    {
        if (items.count == 1)
        {
            [undo setActionName:NSLocalizedString(@"Add Job To Queue", @"Queue undo action name")];
        }
        else
        {
            [undo setActionName:NSLocalizedString(@"Add Jobs To Queue", @"Queue undo action name")];
        }
    }

    [self.tableView endUpdates];
    [self updateQueueStats];
    [self.items commit];
}

- (void)removeQueueItemAtIndex:(NSUInteger)index
{
    [self removeQueueItemsAtIndexes:[NSIndexSet indexSetWithIndex:index]];
}

- (void)removeQueueItemsAtIndexes:(NSIndexSet *)indexes
{
    NSParameterAssert(indexes);

    if (indexes.count == 0)
    {
        return;
    }

    [self.items beginTransaction];
    [self.tableView beginUpdates];

    NSArray<HBQueueItem *> *removeItems = [self.items objectsAtIndexes:indexes];

    if (self.items.count > indexes.lastIndex)
    {
        [self.items removeObjectsAtIndexes:indexes];
    }

    [self.tableView removeRowsAtIndexes:indexes withAnimation:NSTableViewAnimationSlideUp];
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:indexes.firstIndex] byExtendingSelection:NO];

    NSUndoManager *undo = self.window.undoManager;
    [[undo prepareWithInvocationTarget:self] addQueueItems:removeItems atIndexes:indexes];

    if (!undo.isUndoing)
    {
        if (indexes.count == 1)
        {
            [undo setActionName:NSLocalizedString(@"Remove Job From Queue", @"Queue undo action name")];
        }
        else
        {
            [undo setActionName:NSLocalizedString(@"Remove Jobs From Queue", @"Queue undo action name")];
        }
    }

    [self.tableView endUpdates];
    [self updateQueueStats];
    [self.items commit];
}

- (void)moveQueueItems:(NSArray *)items toIndex:(NSUInteger)index
{
    [self.items beginTransaction];
    [self.tableView beginUpdates];

    NSMutableArray *source = [NSMutableArray array];
    NSMutableArray *dest = [NSMutableArray array];

    for (id object in items.reverseObjectEnumerator)
    {
        NSUInteger sourceIndex = [self.items indexOfObject:object];
        [self.items removeObjectAtIndex:sourceIndex];


        if (sourceIndex < index)
        {
            index--;
        }

        [self.items insertObject:object atIndex:index];

        [source addObject:@(index)];
        [dest addObject:@(sourceIndex)];

        [self.tableView moveRowAtIndex:sourceIndex toIndex:index];
    }

    NSUndoManager *undo = self.window.undoManager;
    [[undo prepareWithInvocationTarget:self] moveQueueItemsAtIndexes:source toIndexes:dest];

    if (!undo.isUndoing)
    {
        if (items.count == 1)
        {
            [undo setActionName:NSLocalizedString(@"Move Job in Queue", @"Queue undo action name")];
        }
        else
        {
            [undo setActionName:NSLocalizedString(@"Move Jobs in Queue", @"Queue undo action name")];
        }
    }

    [self.tableView endUpdates];
    [self.items commit];
}

- (void)moveQueueItemsAtIndexes:(NSArray *)source toIndexes:(NSArray *)dest
{
    [self.items beginTransaction];
    [self.tableView beginUpdates];

    NSMutableArray *newSource = [NSMutableArray array];
    NSMutableArray *newDest = [NSMutableArray array];

    for (NSInteger idx = source.count - 1; idx >= 0; idx--)
    {
        NSUInteger sourceIndex = [source[idx] integerValue];
        NSUInteger destIndex = [dest[idx] integerValue];

        [newSource addObject:@(destIndex)];
        [newDest addObject:@(sourceIndex)];

        id obj = [self.items objectAtIndex:sourceIndex];
        [self.items removeObjectAtIndex:sourceIndex];
        [self.items insertObject:obj atIndex:destIndex];

        [self.tableView moveRowAtIndex:sourceIndex toIndex:destIndex];
    }

    NSUndoManager *undo = self.window.undoManager;
    [[undo prepareWithInvocationTarget:self] moveQueueItemsAtIndexes:newSource toIndexes:newDest];

    if (!undo.isUndoing)
    {
        if (source.count == 1)
        {
            [undo setActionName:NSLocalizedString(@"Move Job in Queue", @"Queue undo action name")];
        }
        else
        {
            [undo setActionName:NSLocalizedString(@"Move Jobs in Queue", @"Queue undo action name")];
        }
    }

    [self.tableView endUpdates];
    [self.items commit];
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification
{
    if ([self.window occlusionState] & NSWindowOcclusionStateVisible)
    {
        self.visible = YES;
        self.progressTextField.attributedStringValue = self.progressInfo;
    }
    else
    {
        self.visible = NO;
    }
}

- (void)updateProgress:(NSString *)info progress:(double)progress hidden:(BOOL)hidden
{
    self.progressInfo = [[NSAttributedString alloc] initWithString:info attributes:_monospacedAttr];
    if (self.visible)
    {
        self.progressTextField.attributedStringValue = _progressInfo;
    }
    [self.controller setQueueInfo:_progressInfo progress:progress hidden:hidden];
}

/**
 *  Updates the queue status label.
 */
- (void)updateQueueStats
{
    // lets get the stats on the status of the queue array
    NSUInteger pendingCount = 0;
    NSUInteger completedCount = 0;

    for (HBQueueItem *item in self.items)
    {
        if (item.state == HBQueueItemStateReady)
        {
            pendingCount++;
        }
        if (item.state == HBQueueItemStateCompleted)
        {
            completedCount++;
        }
    }

    NSString *string;
    if (pendingCount == 0)
    {
        string = NSLocalizedString(@"No encode pending", @"Queue status");
    }
    else if (pendingCount == 1)
    {
        string = [NSString stringWithFormat: NSLocalizedString(@"%d encode pending", @"Queue status"), pendingCount];
    }
    else
    {
        string = [NSString stringWithFormat: NSLocalizedString(@"%d encodes pending", @"Queue status"), pendingCount];
    }

    self.countTextField.stringValue = string;

    self.pendingItemsCount = pendingCount;
    self.completedItemsCount = completedCount;
}

#pragma mark - Queue Job Processing

- (BOOL)_isDiskSpaceLowAtURL:(NSURL *)url
{
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HBQueuePauseIfLowSpace"])
    {
        NSURL *volumeURL = nil;
        NSDictionary<NSURLResourceKey, id> *attrs = [url resourceValuesForKeys:@[NSURLIsVolumeKey, NSURLVolumeURLKey] error:NULL];
        long long minCapacity = [[[NSUserDefaults standardUserDefaults] stringForKey:@"HBQueueMinFreeSpace"] longLongValue] * 1000000000;

        volumeURL = [attrs[NSURLIsVolumeKey] boolValue] ? url : attrs[NSURLVolumeURLKey];

        if (volumeURL)
        {
            [volumeURL removeCachedResourceValueForKey:NSURLVolumeAvailableCapacityKey];
            attrs = [volumeURL resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey] error:NULL];

            if (attrs[NSURLVolumeAvailableCapacityKey])
            {
                if ([attrs[NSURLVolumeAvailableCapacityKey] longLongValue] < minCapacity)
                {
                    return YES;
                }
            }
        }
    }

    return NO;
}

/**
 * Used to get the next pending queue item and return it if found
 */
- (HBQueueItem *)getNextPendingQueueItem
{
    for (HBQueueItem *item in self.items)
    {
        if (item.state == HBQueueItemStateReady)
        {
            return item;
        }
    }
    return nil;
}

/**
 *  Starts the queue
 */
- (void)encodeNextQueueItem
{
    [self.items beginTransaction];
    self.currentItem = nil;

    // since we have completed an encode, we go to the next
    if (self.stop)
    {
        [HBUtilities writeToActivityLog:"Queue manually stopped"];

        self.stop = NO;
        [self.core allowSleep];
    }
    else
    {
        // Check to see if there are any more pending items in the queue
        HBQueueItem *nextItem = [self getNextPendingQueueItem];

        if (nextItem && [self _isDiskSpaceLowAtURL:nextItem.outputURL])
        {
            // Disk space is low, show an alert
            [HBUtilities writeToActivityLog:"Queue Stopped, low space on destination disk"];

            [self queueLowDiskSpaceAlert];
        }
        // If we still have more pending items in our queue, lets go to the next one
        else if (nextItem)
        {
            // now we mark the queue item as working so another instance can not come along and try to scan it while we are scanning
            nextItem.state = HBQueueItemStateWorking;

            // Tell HB to output a new activity log file for this encode
            self.currentLog = [[HBJobOutputFileWriter alloc] initWithJob:nextItem.job];
            if (self.currentLog)
            {
                [[HBOutputRedirect stderrRedirect] addListener:self.currentLog];
                [[HBOutputRedirect stdoutRedirect] addListener:self.currentLog];
            }

            self.currentItem = nextItem;
            [self reloadQueueItemAtIndex:[self.items indexOfObject:nextItem]];

            // now we can go ahead and scan the new pending queue item
            [self encodeItem:nextItem];

            // erase undo manager history
            [self.window.undoManager removeAllActions];
        }
        else
        {
            [HBUtilities writeToActivityLog:"Queue Done, there are no more pending encodes"];

            // Since there are no more items to encode, go to queueCompletedAlerts
            // for user specified alerts after queue completed
            [self queueCompletedAlerts];

            [self.core allowSleep];
        }
    }
    [self.items commit];
}

- (void)completedItem:(HBQueueItem *)item result:(HBCoreResult)result;
{
    NSParameterAssert(item);
    [self.items beginTransaction];

    // Since we are done with this encode, tell output to stop writing to the
    // individual encode log.
    [[HBOutputRedirect stderrRedirect] removeListener:self.currentLog];
    [[HBOutputRedirect stdoutRedirect] removeListener:self.currentLog];

    self.currentLog = nil;

    // Check to see if the encode state has not been canceled
    // to determine if we should send it to external app.
    if (result != HBCoreResultCanceled)
    {
        // Send to tagger
        [self sendToExternalApp:item];
    }

    // Mark the encode just finished
    switch (result) {
        case HBCoreResultDone:
            item.state = HBQueueItemStateCompleted;
            break;
        case HBCoreResultCanceled:
            item.state = HBQueueItemStateCanceled;
            break;
        default:
            item.state = HBQueueItemStateFailed;
            break;
    }

    if ([self.items containsObject:item])
    {
        [self reloadQueueItemAtIndex:[self.items indexOfObject:item]];
    }
    [self.window.toolbar validateVisibleItems];
    [self.items commit];

    // Update UI
    NSString *info = nil;
    switch (result) {
        case HBCoreResultDone:
            info = NSLocalizedString(@"Encode Finished.", @"Queue status");
            [self itemCompletedAlerts:item result:result];
            break;
        case HBCoreResultCanceled:
            info = NSLocalizedString(@"Encode Canceled.", @"Queue status");
            break;
        default:
            info = NSLocalizedString(@"Encode Failed.", @"Queue status");
            [self itemCompletedAlerts:item result:result];
            break;
    }
    [self updateProgress:info progress:1.0 hidden:YES];

    // Restore dock icon
    [self.dockTile updateDockIcon:-1.0 withETA:@""];
    self.dockIconProgress = 0;
}

/**
 * Here we actually tell hb_scan to perform the source scan, using the path to source and title number
 */
- (void)encodeItem:(HBQueueItem *)item
{
    NSParameterAssert(item);

    // Progress handler
    void (^progressHandler)(HBState state, HBProgress progress, NSString *info) = ^(HBState state, HBProgress progress, NSString *info)
    {
        [self updateProgress:info progress:0 hidden:NO];
    };

    // Completion handler
    void (^completionHandler)(HBCoreResult result) = ^(HBCoreResult result)
    {
        if (result == HBCoreResultDone)
        {
            [self realEncodeItem:item];
        }
        else
        {
            [self completedItem:item result:result];
            [self encodeNextQueueItem];
        }
    };

    // Only scan 10 previews before an encode - additional previews are
    // only useful for autocrop and static previews, which are already taken care of at this point
    [self.core scanURL:item.fileURL
            titleIndex:item.job.titleIdx
              previews:10
           minDuration:0
       progressHandler:progressHandler
     completionHandler:completionHandler];
}

/**
 * This assumes that we have re-scanned and loaded up a new queue item to send to libhb
 */
- (void)realEncodeItem:(HBQueueItem *)item
{
    NSParameterAssert(item);

    HBJob *job = item.job;

    // Reset the title in the job.
    job.title = self.core.titles.firstObject;

    NSParameterAssert(job);

    HBStateFormatter *formatter = [[HBStateFormatter alloc] init];
    formatter.title = job.outputFileName;
    self.core.stateFormatter = formatter;

    // Progress handler
    void (^progressHandler)(HBState state, HBProgress progress, NSString *info) = ^(HBState state, HBProgress progress, NSString *info)
    {
        if (state == HBStateWorking)
        {
            // Update dock icon
            if (self.dockIconProgress < 100.0 * progress.percent)
            {
                [self.dockTile updateDockIcon:progress.percent hours:progress.hours minutes:progress.minutes seconds:progress.seconds];
                self.dockIconProgress += dockTileUpdateFrequency;
            }
        }
        else if (state == HBStateMuxing)
        {
            [self.dockTile updateDockIcon:1.0 withETA:@""];
        }

        // Update UI
        [self updateProgress:info progress:progress.percent hidden:NO];
    };

    // Completion handler
    void (^completionHandler)(HBCoreResult result) = ^(HBCoreResult result)
    {
        [self completedItem:item result:result];
        [self encodeNextQueueItem];
    };

    // We should be all setup so let 'er rip
    [self.core encodeJob:job progressHandler:progressHandler completionHandler:completionHandler];

    // We are done using the title, remove it from the job
    job.title = nil;
}

/**
 * Cancels the current job
 */
- (void)doCancelCurrentItem
{
    if (self.core.state == HBStateScanning)
    {
        [self.core cancelScan];
    }
    else
    {
        [self.core cancelEncode];
    }
}

/**
 * Cancels the current job and starts processing the next in queue.
 */
- (void)cancelCurrentItemAndContinue
{
    [self doCancelCurrentItem];
}

/**
 * Cancels the current job and stops libhb from processing the remaining encodes.
 */
- (void)cancelCurrentItemAndStop
{
    self.stop = YES;
    [self doCancelCurrentItem];
}

/**
 * Finishes the current job and stops libhb from processing the remaining encodes.
 */
- (void)finishCurrentAndStop
{
    self.stop = YES;
}

#pragma mark - Encode Done Actions

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification
{
    // Show the file in Finder when a done notification was clicked.
    NSString *path = notification.userInfo[@"Path"];
    if ([path isKindOfClass:[NSString class]] && path.length)
    {
        NSURL *fileURL = [NSURL fileURLWithPath:path];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];
    }
}

- (void)showNotificationWithTitle:(NSString *)title description:(NSString *)description url:(NSURL *)fileURL playSound:(BOOL)playSound
{
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = title;
    notification.informativeText = description;
    notification.soundName = playSound ? NSUserNotificationDefaultSoundName : nil;
    notification.hasActionButton = YES;
    notification.actionButtonTitle = NSLocalizedString(@"Show", @"Notification -> Show in Finder");
    notification.userInfo = @{ @"Path": fileURL.path };
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

/**
 *  Sends the URL to the external app
 *  selected in the preferences.
 *
 *  @param job the job of the file to send
 */
- (void)sendToExternalApp:(HBQueueItem *)item
{
    // This end of encode action is called as each encode rolls off of the queue
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HBSendToAppEnabled"] == YES)
    {
#ifdef __SANDBOX_ENABLED__
        BOOL accessingSecurityScopedResource = [item.outputURL startAccessingSecurityScopedResource];
#endif

        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSString *app = [workspace fullPathForApplication:[[NSUserDefaults standardUserDefaults] objectForKey:@"HBSendToApp"]];

        if (app)
        {
            if (![workspace openFile:item.completeOutputURL.path withApplication:app])
            {
                [HBUtilities writeToActivityLog:"Failed to send file to: %s", app];
            }
        }
        else
        {
            [HBUtilities writeToActivityLog:"Send file to: app not found"];
        }

#ifdef __SANDBOX_ENABLED__
        if (accessingSecurityScopedResource)
        {
            [item.outputURL stopAccessingSecurityScopedResource];
        }
#endif
    }
}

/**
 *  Runs the alert for a single job
 */
- (void)itemCompletedAlerts:(HBQueueItem *)item result:(HBCoreResult)result
{
    // Both the Notification and Sending to tagger can be done as encodes roll off the queue
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionNotification ||
        [[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionAlertAndNotification)
    {
        // If Play System Alert has been selected in Preferences
        bool playSound = [[NSUserDefaults standardUserDefaults] boolForKey:@"HBAlertWhenDoneSound"];

        NSString *title;
        NSString *description;
        if (result == HBCoreResultDone)
        {
            title = NSLocalizedString(@"Put down that cocktail…", @"Queue notification alert message");
            description = [NSString stringWithFormat:NSLocalizedString(@"Your encode %@ is done!", @"Queue done notification message"),
                                     item.outputFileName];

        }
        else
        {
            title = NSLocalizedString(@"Encode failed", @"Queue done notification failed message");
            description = [NSString stringWithFormat:NSLocalizedString(@"Your encode %@ couldn't be completed.", @"Queue done notification message"),
                           item.outputFileName];
        }

        [self showNotificationWithTitle:title
                            description:description
                                    url:item.completeOutputURL
                                playSound:playSound];
    }
}

/**
 *  Runs the global queue completed alerts
 */
- (void)queueCompletedAlerts
{
    // If Play System Alert has been selected in Preferences
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"HBAlertWhenDoneSound"] == YES)
    {
        NSBeep();
    }

    // If Alert Window or Window and Notification has been selected
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionAlert ||
        [[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionAlertAndNotification)
    {
        // On Screen Notification
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Put down that cocktail…", @"Queue done alert message")];
        [alert setInformativeText:NSLocalizedString(@"Your HandBrake queue is done!", @"Queue done alert informative text")];
        [NSApp requestUserAttention:NSCriticalRequest];
        [alert runModal];
    }

    // If sleep has been selected
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionSleep)
    {
        // Sleep
        NSDictionary *errorDict;
        NSAppleScript *scriptObject = [[NSAppleScript alloc] initWithSource:
                                       @"tell application \"Finder\" to sleep"];
        [scriptObject executeAndReturnError: &errorDict];
    }
    // If Shutdown has been selected
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionShutDown)
    {
        // Shut Down
        NSDictionary *errorDict;
        NSAppleScript *scriptObject = [[NSAppleScript alloc] initWithSource:@"tell application \"Finder\" to shut down"];
        [scriptObject executeAndReturnError: &errorDict];
    }
}

- (void)queueLowDiskSpaceAlert
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"Your destination disk is almost full.", @"Queue -> disk almost full alert message")];
    [alert setInformativeText:NSLocalizedString(@"You need to make more space available on your destination disk.",@"Queue -> disk almost full alert informative text")];
    [NSApp requestUserAttention:NSCriticalRequest];
    [alert runModal];
}

#pragma mark - Queue Item Controls

/**
 * Delete encodes from the queue window and accompanying array
 * Also handling first cancelling the encode if in fact its currently encoding.
 */
- (IBAction)removeSelectedQueueItem:(id)sender
{
    if ([self.items beginTransaction] == HBDistributedArrayContentReload)
    {
        // Do not execture the action if the array changed.
        [self.items commit];
        return;
    }

    NSMutableIndexSet *targetedRows = [[self.tableView targetedRowIndexes] mutableCopy];

    if (targetedRows.count)
    {
        // if this is a currently encoding job, we need to be sure to alert the user,
        // to let them decide to cancel it first, then if they do, we can come back and
        // remove it
        NSIndexSet *workingIndexes = [self.items indexesOfObjectsUsingBlock:^BOOL(HBQueueItem *item) {
            return item.state == HBQueueItemStateWorking;
        }];

        if ([targetedRows containsIndexes:workingIndexes])
        {
            [targetedRows removeIndexes:workingIndexes];
            NSArray<HBQueueItem *> *workingItems = [self.items filteredArrayUsingBlock:^BOOL(HBQueueItem *item) {
                return item.state == HBQueueItemStateWorking;
            }];

            if ([workingItems containsObject:self.currentItem])
            {
                NSString *alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Stop This Encode and Remove It?", @"Queue Stop Alert -> stop and remove message")];

                // Which window to attach the sheet to?
                NSWindow *targetWindow = self.window;
                if ([sender respondsToSelector: @selector(window)])
                {
                    targetWindow = [sender window];
                }

                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:alertTitle];
                [alert setInformativeText:NSLocalizedString(@"Your movie will be lost if you don't continue encoding.", @"Queue Stop Alert -> stop and remove informative text")];
                [alert addButtonWithTitle:NSLocalizedString(@"Keep Encoding", @"Queue Stop Alert -> stop and remove first button")];
                [alert addButtonWithTitle:NSLocalizedString(@"Stop Encoding and Delete", @"Queue Stop Alert -> stop and remove second button")];
                [alert setAlertStyle:NSAlertStyleCritical];

                [alert beginSheetModalForWindow:targetWindow completionHandler:^(NSModalResponse returnCode) {
                    if (returnCode == NSAlertSecondButtonReturn)
                    {
                        [self.items beginTransaction];

                        NSInteger index = [self.items indexOfObject:self.currentItem];
                        [self cancelCurrentItemAndContinue];

                        [self removeQueueItemAtIndex:index];
                        [self.items commit];
                    }
                }];
            }
        }

        // remove the non working items immediately
        [self removeQueueItemsAtIndexes:targetedRows];
    }
    [self.items commit];
}

/**
 * Show the finished encode in the finder
 */
- (IBAction)revealSelectedQueueItems:(id)sender
{
    NSIndexSet *targetedRows = [self.tableView targetedRowIndexes];
    NSMutableArray<NSURL *> *urls = [[NSMutableArray alloc] init];

    NSUInteger currentIndex = [targetedRows firstIndex];
    while (currentIndex != NSNotFound) {
        NSURL *url = [[self.items objectAtIndex:currentIndex] completeOutputURL];
        [urls addObject:url];
        currentIndex = [targetedRows indexGreaterThanIndex:currentIndex];
    }

    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (IBAction)revealSelectedQueueItemsSources:(id)sender
{
    NSIndexSet *targetedRows = [self.tableView targetedRowIndexes];
    NSMutableArray<NSURL *> *urls = [[NSMutableArray alloc] init];

    NSUInteger currentIndex = [targetedRows firstIndex];
    while (currentIndex != NSNotFound) {
        NSURL *url = [[self.items objectAtIndex:currentIndex] fileURL];
        [urls addObject:url];
        currentIndex = [targetedRows indexGreaterThanIndex:currentIndex];
    }

    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (void)remindUserOfSleepOrShutdown
{
    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionSleep)
    {
        // Warn that computer will sleep after encoding
        NSBeep();
        [NSApp requestUserAttention:NSCriticalRequest];

        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"The computer will sleep after encoding is done.", @"Queue Done Alert -> sleep message")];
        [alert setInformativeText:NSLocalizedString(@"You have selected to sleep the computer after encoding. To turn off sleeping, go to the HandBrake preferences.", @"Queue Done Alert -> sleep informative text")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"Queue Done Alert -> sleep first button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Preferences…", @"Queue Done Alert -> sleep second button")];

        NSInteger response = [alert runModal];
        if (response == NSAlertSecondButtonReturn)
        {
            [self.delegate showPreferencesWindow:nil];
        }
    }
    else if ([[NSUserDefaults standardUserDefaults] integerForKey:@"HBAlertWhenDone"] == HBDoneActionShutDown)
    {
        // Warn that computer will shut down after encoding
        NSBeep();
        [NSApp requestUserAttention:NSCriticalRequest];

        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"The computer will shut down after encoding is done.", @"Queue Done Alert -> shut down message")];
        [alert setInformativeText:NSLocalizedString(@"You have selected to shut down the computer after encoding. To turn off shut down, go to the HandBrake preferences.", @"Queue Done Alert -> shut down informative text")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"Queue Done Alert -> shut down first button")];
        [alert addButtonWithTitle:NSLocalizedString(@"Preferences…", @"Queue Done Alert -> shut down second button")];

        NSInteger response = [alert runModal];
        if (response == NSAlertSecondButtonReturn)
        {
            [self.delegate showPreferencesWindow:nil];
        }
    }
}

/**
 * Rip: puts up an alert before ultimately calling doRip
 */
- (IBAction)rip:(id)sender
{
    // Rip or Cancel ?
    if (self.core.state == HBStateWorking || self.core.state == HBStatePaused || self.core.state == HBStateSearching)
    {
        [self cancelRip:sender];
    }
    // If there are pending items in the queue, then this is a rip the queue
    else if (self.pendingItemsCount > 0)
    {
        // We check to see if we need to warn the user that the computer will go to sleep
        // or shut down when encoding is finished
        [self remindUserOfSleepOrShutdown];

        [self.core preventSleep];
        [self encodeNextQueueItem];
    }
}

/**
 * Displays an alert asking user if the want to cancel encoding of current item.
 * Cancel: returns immediately after posting the alert. Later, when the user
 * acknowledges the alert, doCancelCurrentItem is called.
 */
- (IBAction)cancelRip:(id)sender
{
    // Which window to attach the sheet to?
    NSWindow *window = self.window;
    if ([sender respondsToSelector:@selector(window)])
    {
        window = [sender window];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:NSLocalizedString(@"You are currently encoding. What would you like to do?", @"Queue Alert -> cancel rip message")];
    [alert setInformativeText:NSLocalizedString(@"Select Continue Encoding to dismiss this dialog without making changes.", @"Queue Alert -> cancel rip informative text")];
    [alert addButtonWithTitle:NSLocalizedString(@"Continue Encoding", @"Queue Alert -> cancel rip first button")];
    [alert addButtonWithTitle:NSLocalizedString(@"Skip Current Job", @"Queue Alert -> cancel rip second button")];
    [alert addButtonWithTitle:NSLocalizedString(@"Stop After Current Job", @"Queue Alert -> cancel rip third button")];
    [alert addButtonWithTitle:NSLocalizedString(@"Stop All", @"Queue Alert -> cancel rip fourth button")];
    [alert setAlertStyle:NSAlertStyleCritical];

    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertSecondButtonReturn)
        {
            [self cancelCurrentItemAndContinue];
        }
        else if (returnCode == NSAlertThirdButtonReturn)
        {
            [self finishCurrentAndStop];
        }
        else if (returnCode == NSAlertThirdButtonReturn + 1)
        {
            [self cancelCurrentItemAndStop];
        }
    }];
}

/**
 * Starts or cancels the processing of items depending on the current state
 */
- (IBAction)toggleStartCancel:(id)sender
{
    HBState s = self.core.state;
    if ((s == HBStatePaused) || (s == HBStateWorking) || (s == HBStateMuxing))
    {
        [self cancelRip:self];
    }
    else if (self.pendingItemsCount > 0)
    {
        [self rip:self];
    }
}

/**
 * Toggles the pause/resume state of libhb
 */
- (IBAction)togglePauseResume:(id)sender
{
    HBState s = self.core.state;
    if (s == HBStatePaused)
    {
        [self.core resume];
        [self.core preventSleep];
    }
    else if (s == HBStateWorking || s == HBStateMuxing)
    {
        [self.core pause];
        [self.core allowSleep];
    }
}

/**
 *  Resets the item state to ready.
 */
- (IBAction)resetJobState:(id)sender
{
    if ([self.items beginTransaction] == HBDistributedArrayContentReload)
    {
        // Do not execture the action if the array changed.
        [self.items commit];
        return;
    }

    NSIndexSet *targetedRows = [self.tableView targetedRowIndexes];
    NSMutableIndexSet *updatedIndexes = [NSMutableIndexSet indexSet];

    NSUInteger currentIndex = [targetedRows firstIndex];
    while (currentIndex != NSNotFound) {
        HBQueueItem *item = self.items[currentIndex];

        if (item.state == HBQueueItemStateCanceled || item.state == HBQueueItemStateCompleted || item.state == HBQueueItemStateFailed)
        {
            item.state = HBQueueItemStateReady;
            [updatedIndexes addIndex:currentIndex];
        }
        currentIndex = [targetedRows indexGreaterThanIndex:currentIndex];
    }

    [self reloadQueueItemsAtIndexes:updatedIndexes];
    [self.items commit];
}

- (void)editQueueItem:(HBQueueItem *)item
{
    NSParameterAssert(item);
    [self.items beginTransaction];

    if (item != self.currentItem)
    {
        item.state = HBQueueItemStateWorking;

        NSUInteger row = [self.items indexOfObject:item];
        [self reloadQueueItemAtIndex:row];

        [self.controller openJob:[item.job copy] completionHandler:^(BOOL result) {
            [self.items beginTransaction];
            if (result)
            {
                // Now that source is loaded and settings applied, delete the queue item from the queue
                NSInteger index = [self.items indexOfObject:item];
                item.state = HBQueueItemStateReady;
                [self removeQueueItemAtIndex:index];
            }
            else
            {
                item.state = HBQueueItemStateFailed;
                NSBeep();
            }
            [self.items commit];
        }];
    }
    else
    {
        NSBeep();
    }

    [self.items commit];
}

/**
 * Send the selected queue item back to the main window for rescan and possible edit.
 */
- (IBAction)editSelectedQueueItem:(id)sender
{
    if ([self.items beginTransaction] == HBDistributedArrayContentReload)
    {
        // Do not execture the action if the array changed.
        [self.items commit];
        return;
    }

    NSInteger row = self.tableView.clickedRow;
    if (row != NSNotFound)
    {
        // if this is a currently encoding item, we need to be sure to alert the user,
        // to let them decide to cancel it first, then if they do, we can come back and
        // remove it
        HBQueueItem *item = self.items[row];
        if (item == self.currentItem)
        {
            NSString *alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Stop This Encode and Edit It?", @"Queue Edit Alert -> stop and edit message")];

            // Which window to attach the sheet to?
            NSWindow *docWindow = self.window;
            if ([sender respondsToSelector: @selector(window)])
            {
                docWindow = [sender window];
            }

            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:alertTitle];
            [alert setInformativeText:NSLocalizedString(@"Your movie will be lost if you don't continue encoding.", @"Queue Edit Alert -> stop and edit informative text")];
            [alert addButtonWithTitle:NSLocalizedString(@"Keep Encoding", @"Queue Edit Alert -> stop and edit first button")];
            [alert addButtonWithTitle:NSLocalizedString(@"Stop Encoding and Edit", @"Queue Edit Alert -> stop and edit second button")];
            [alert setAlertStyle:NSAlertStyleCritical];

            [alert beginSheetModalForWindow:docWindow completionHandler:^(NSModalResponse returnCode) {
                if (returnCode == NSAlertSecondButtonReturn)
                {
                    [self editQueueItem:item];
                }
            }];
        }
        else if (item.state != HBQueueItemStateWorking)
        {
            [self editQueueItem:item];
        }
    }

    [self.items commit];
}

- (IBAction)clearAll:(id)sender
{
    [self.items beginTransaction];
    NSIndexSet *indexes = [self.items indexesOfObjectsUsingBlock:^BOOL(HBQueueItem *item) {
        return (item.state != HBQueueItemStateWorking);
    }];
    [self removeQueueItemsAtIndexes:indexes];
    [self.items commit];
}

- (IBAction)clearCompleted:(id)sender
{
    [self.items beginTransaction];
    NSIndexSet *indexes = [self.items indexesOfObjectsUsingBlock:^BOOL(HBQueueItem *item) {
        return (item.state == HBQueueItemStateCompleted);
    }];
    [self removeQueueItemsAtIndexes:indexes];
    [self.items commit];
}

#pragma mark - NSTableView data source

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {

    HBQueueItemView *view = [tableView makeViewWithIdentifier:@"MainCell" owner:self];
    HBQueueItem *item = self.items[row];

    view.delegate = self;
    view.item = item;

    return view;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.items.count;
}

- (NSTableCellView *)dummyCell
{
    if (!_dummyCell) {
        _dummyCell = [self.tableView makeViewWithIdentifier:@"MainCellForSizing" owner: self];
        _dummyCellWidth = [NSLayoutConstraint constraintWithItem:_dummyCell
                                                       attribute:NSLayoutAttributeWidth
                                                       relatedBy:NSLayoutRelationEqual
                                                          toItem:nil
                                                       attribute:NSLayoutAttributeNotAnAttribute
                                                      multiplier:1.0f
                                                        constant:500];
        [_dummyCell addConstraint:_dummyCellWidth];
    }
    return _dummyCell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
    HBQueueItem *item = self.items[row];

    if (item.expanded)
    {
        CGFloat width = tableView.frame.size.width;
        self.dummyCellWidth.constant = width;
        self.dummyCell.textField.preferredMaxLayoutWidth = width - 60;
        self.dummyCell.textField.attributedStringValue = item.attributedDescription;

        CGFloat height = self.dummyCell.fittingSize.height;
        return height;
    }
    else
    {
        return 20;
    }
}

- (void)toggleRowsAtIndexes:(NSIndexSet *)rowIndexes expand:(BOOL)expand
{
    NSMutableIndexSet *rowsToExpand = [NSMutableIndexSet indexSet];
    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        HBQueueItem *item = self.items[index];
        BOOL expanded = item.expanded;
        if (expanded != expand)
        {
            item.expanded = !expanded;
            [rowsToExpand addIndex:index];
        }

        HBQueueItemView *itemView = (HBQueueItemView *)[self.tableView viewAtColumn:0 row:index makeIfNecessary:NO];
        if (expand)
        {
            [itemView expand];
        }
        else
        {
            [itemView collapse];
        }
    }];
    [self.tableView noteHeightOfRowsWithIndexesChanged:rowsToExpand];
}

#pragma mark NSQueueItemView delegate

- (void)removeQueueItem:(nonnull HBQueueItem *)item
{
    NSUInteger index = [self.items indexOfObject:item];
    [self removeQueueItemAtIndex:index];
}

- (void)revealQueueItem:(nonnull HBQueueItem *)item
{
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[item.completeOutputURL]];
}

- (void)toggleQueueItemHeight:(nonnull HBQueueItem *)item
{
    NSInteger row = [self.items indexOfObject:item];
    [self toggleRowsAtIndexes:[NSIndexSet indexSetWithIndex:row] expand:!item.expanded];
}

#pragma mark NSTableView delegate

- (void)HB_deleteSelectionFromTableView:(NSTableView *)tableView
{
    [self removeSelectedQueueItem:tableView];
}

- (void)HB_expandSelectionFromTableView:(NSTableView *)tableView
{
    NSIndexSet *rowIndexes = [self.tableView selectedRowIndexes];
    [self toggleRowsAtIndexes:rowIndexes expand:YES];
}

- (void)HB_collapseSelectionFromTableView:(NSTableView *)tableView;
{
    NSIndexSet *rowIndexes = [self.tableView selectedRowIndexes];
    [self toggleRowsAtIndexes:rowIndexes expand:NO];
}

- (BOOL)tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard;
{
    NSArray<HBQueueItem *> *items = [self.items objectsAtIndexes:rowIndexes];
    // Dragging is only allowed of the pending items.
    if (items[0].state != HBQueueItemStateReady)
    {
        return NO;
    }

    self.dragNodesArray = items;

    // Provide data for our custom type, and simple NSStrings.
    [pboard declareTypes:@[DragDropSimplePboardType] owner:self];

    // the actual data doesn't matter since DragDropSimplePboardType drags aren't recognized by anyone but us!.
    [pboard setData:[NSData data] forType:DragDropSimplePboardType];

    return YES;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation
{
    // Don't allow dropping ONTO an item since they can't really contain any children.
    BOOL isOnDropTypeProposal = dropOperation == NSTableViewDropOn;
    if (isOnDropTypeProposal)
    {
        return NSDragOperationNone;
    }

    // We do not let the user drop a pending item before or *above*
    // already finished or currently encoding items.
    NSInteger encodingRow = [self.items indexOfObject:self.currentItem];
    if (encodingRow != NSNotFound && row <= encodingRow)
    {
        return NSDragOperationNone;
        row = MAX(row, encodingRow);
	}

    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation
{
    [self moveQueueItems:self.dragNodesArray toIndex:row];
    return YES;
}

@end

@implementation HBQueueController (TouchBar)

@dynamic touchBar;

static NSTouchBarItemIdentifier HBTouchBarMain = @"fr.handbrake.queueWindowTouchBar";

static NSTouchBarItemIdentifier HBTouchBarRip = @"fr.handbrake.rip";
static NSTouchBarItemIdentifier HBTouchBarPause = @"fr.handbrake.pause";

- (NSTouchBar *)makeTouchBar
{
    NSTouchBar *bar = [[NSTouchBar alloc] init];
    bar.delegate = self;

    bar.defaultItemIdentifiers = @[HBTouchBarRip, HBTouchBarPause];

    bar.customizationIdentifier = HBTouchBarMain;
    bar.customizationAllowedItemIdentifiers = @[HBTouchBarRip, HBTouchBarPause];

    return bar;
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
    if ([identifier isEqualTo:HBTouchBarRip])
    {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.customizationLabel = NSLocalizedString(@"Start/Stop Encoding", @"Touch bar");

        NSButton *button = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameTouchBarPlayTemplate] target:self action:@selector(toggleStartCancel:)];

        item.view = button;
        return item;
    }
    else if ([identifier isEqualTo:HBTouchBarPause])
    {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        item.customizationLabel = NSLocalizedString(@"Pause/Resume Encoding", @"Touch bar");

        NSButton *button = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameTouchBarPauseTemplate] target:self action:@selector(togglePauseResume:)];

        item.view = button;
        return item;
    }

    return nil;
}

- (void)_touchBar_updateButtonsStateForQueueCore:(HBState)state;
{
    NSButton *ripButton = (NSButton *)[[self.touchBar itemForIdentifier:HBTouchBarRip] view];
    NSButton *pauseButton = (NSButton *)[[self.touchBar itemForIdentifier:HBTouchBarPause] view];

    if (state == HBStateScanning || state == HBStateWorking || state == HBStateSearching || state == HBStateMuxing)
    {
        ripButton.image = [NSImage imageNamed:NSImageNameTouchBarRecordStopTemplate];
        pauseButton.image = [NSImage imageNamed:NSImageNameTouchBarPauseTemplate];
    }
    else if (state == HBStatePaused)
    {
        ripButton.image = [NSImage imageNamed:NSImageNameTouchBarRecordStopTemplate];
        pauseButton.image = [NSImage imageNamed:NSImageNameTouchBarPlayTemplate];
    }
    else if (state == HBStateIdle)
    {
        ripButton.image = [NSImage imageNamed:NSImageNameTouchBarPlayTemplate];
        pauseButton.image = [NSImage imageNamed:NSImageNameTouchBarPauseTemplate];
    }
}

- (void)_touchBar_validateUserInterfaceItems
{
    for (NSTouchBarItemIdentifier identifier in self.touchBar.itemIdentifiers) {
        NSTouchBarItem *item = [self.touchBar itemForIdentifier:identifier];
        NSView *view = item.view;
        if ([view isKindOfClass:[NSButton class]]) {
            NSButton *button = (NSButton *)view;
            BOOL enabled = [self validateUserIterfaceItemForAction:button.action];
            button.enabled = enabled;
        }
    }
}

@end
