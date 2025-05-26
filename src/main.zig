const std = @import("std");
const print = std.debug.print;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const ArrayList = std.ArrayList;

const NUM_THREADS: u32 = 4;
const MAX_WAIT_TIME_MS: u64 = 1000;

const Transaction = struct {
    id: u32,
    timestamp: i64,
    thread_handle: ?Thread = null,
    
    const Self = @This();
    
    pub fn init(id: u32) Self {
        return Self{
            .id = id,
            .timestamp = std.time.milliTimestamp(),
        };
    }
};

const Resource = struct {
    item_id: []const u8,
    valor_lock: bool,
    transacao_holder: ?u32,
    fila: ArrayList(u32),
    mutex: Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, id: []const u8) Self {
        return Self{
            .item_id = id,
            .valor_lock = false,
            .transacao_holder = null,
            .fila = ArrayList(u32).init(allocator),
            .mutex = Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.fila.deinit();
    }
    
    pub fn lock(self: *Self, transaction_id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!self.valor_lock) {
            self.valor_lock = true;
            self.transacao_holder = transaction_id;

            print("Thread T({}) obteve o bloqueio do recurso {s}\n", .{ transaction_id, self.item_id });
            return true;
        } else {
            self.fila.append(transaction_id) catch {};
            print("Thread T({}) está esperando pelo recurso {s} (detido por T({}))\n", .{ transaction_id, self.item_id, self.transacao_holder.? });
            return false;
        }
    }
    
    pub fn unlock(self: *Self, transaction_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.transacao_holder == transaction_id) {
            self.valor_lock = false;
            self.transacao_holder = null;
            print("Thread T({}) liberou o recurso {s}\n", .{ transaction_id, self.item_id });
            
            for (self.fila.items, 0..) |tid, i| {
                if (tid == transaction_id) {
                    _ = self.fila.swapRemove(i);
                    break;
                }
            }
        }
    }
    
    pub fn isLockedBy(self: *Self, transaction_id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.transacao_holder == transaction_id;
    }
    
    pub fn isInQueue(self: *Self, transaction_id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.fila.items) |tid| {
            if (tid == transaction_id) return true;
        }
        return false;
    }
};

const DeadlockDetector = struct {
    transactions: []Transaction,
    resources: []*Resource,
    mutex: Mutex,
    
    const Self = @This();
    
    pub fn init(transactions_: []Transaction, resources: []*Resource) Self {
        return Self{
            .transactions = transactions_,
            .resources = resources,
            .mutex = Mutex{},
        };
    }
    
    pub fn detectAndResolve(self: *Self) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.resources) |resource1| {
            if (resource1.valor_lock and resource1.fila.items.len > 0) {
                const holder1_id = resource1.transacao_holder.?;
                
                for (self.resources) |resource2| {
                    if (std.mem.eql(u8, resource1.item_id, resource2.item_id)) continue;
                    
                    if (resource2.isInQueue(holder1_id) and resource2.valor_lock) {
                        const holder2_id = resource2.transacao_holder.?;
                        if (holder2_id == holder1_id) return null;
                        
                        if (resource1.isInQueue(holder2_id)) {

                            print("DEADLOCK DETECTADO entre T({}) e T({})\n", .{ holder1_id, holder2_id });
                            print("  T({}) possui {s} e espera por {s}\n", .{ holder1_id, resource1.item_id, resource2.item_id });
                            print("  T({}) possui {s} e espera por {s}\n", .{ holder2_id, resource2.item_id, resource1.item_id });
                            
                            const holder1_ts = self.getTransactionTimestamp(holder1_id);
                            const holder2_ts = self.getTransactionTimestamp(holder2_id);
                            
                            if (holder1_ts > holder2_ts) {
                                print("Thread T({}) é finalizada em virtude de deadlock detectado (Wait-Die)\n", .{holder1_id});
                                return holder1_id;
                            } else {
                                print("Thread T({}) é finalizada em virtude de deadlock detectado (Wait-Die)\n", .{holder2_id});
                                return holder2_id;
                            }
                        }
                    }
                }
            }
        }
        return null;
    }
    
    fn getTransactionTimestamp(self: *Self, transaction_id: u32) i64 {
        for (self.transactions) |transaction| {
            if (transaction.id == transaction_id) {
                return transaction.timestamp;
            }
        }
        return 0;
    }
};

var resource_x: Resource = undefined;
var resource_y: Resource = undefined;
var transactions: [NUM_THREADS]Transaction = undefined;
var deadlock_detector: DeadlockDetector = undefined;
var should_terminate: [NUM_THREADS]bool = [_]bool{false} ** NUM_THREADS;
var system_mutex = Mutex{};

fn randomWait() void {
    const seed = @as(u64, @intCast(std.time.milliTimestamp()));
    var rng = std.rand.DefaultPrng.init(seed + std.Thread.getCurrentId());
    const wait_time = rng.random().intRangeAtMost(u64, 100, MAX_WAIT_TIME_MS);
    std.time.sleep(wait_time * 1000000); 
}

fn transactionFunction(transaction_ptr: *Transaction) void {
    const tid = transaction_ptr.id;
    print("Thread T({}) entra em execução\n", .{tid});
    
    while (true) {
        system_mutex.lock();
        if (should_terminate[tid]) {
            system_mutex.unlock();
            print("Thread T({}) está sendo reiniciada após deadlock\n", .{tid});
            transaction_ptr.timestamp = std.time.milliTimestamp();
            should_terminate[tid] = false;
            std.time.sleep(200 * 1000000);
            continue;
        }
        system_mutex.unlock();
        
        // 1. random(t)
        randomWait();
        
        // 2. lock(x)
        while (!resource_x.lock(tid)) {
            std.time.sleep(100 * 1000000); 
            if (deadlock_detector.detectAndResolve()) |victim_id| {
                if (victim_id == tid) {
                    system_mutex.lock();
                    should_terminate[tid] = true;
                    system_mutex.unlock();
                    break;
                }
            }
        }
        
        system_mutex.lock();
        if (should_terminate[tid]) {
            if (resource_x.isLockedBy(tid)) resource_x.unlock(tid);
            if (resource_y.isLockedBy(tid)) resource_y.unlock(tid);
            system_mutex.unlock();
            std.time.sleep(200 * 1000000);
            continue;
        }
        system_mutex.unlock();
        
        // 3. random(t)
        randomWait();
        
        // 4. lock(Y)
        while (!resource_y.lock(tid)) {
            std.time.sleep(100 * 1000000); 
            if (deadlock_detector.detectAndResolve()) |victim_id| {
                if (victim_id == tid) {
                    system_mutex.lock();
                    should_terminate[tid] = true;
                    system_mutex.unlock();
                    break;
                }
            }
        }
        
        system_mutex.lock();
        if (should_terminate[tid]) {
            if (resource_x.isLockedBy(tid)) resource_x.unlock(tid);
            if (resource_y.isLockedBy(tid)) resource_y.unlock(tid);
            system_mutex.unlock();
            continue;
        }
        system_mutex.unlock();
        
        // 5. random(t)
        randomWait();
        
        // 6. unlock(x)
        if (resource_x.isLockedBy(tid)) {
            resource_x.unlock(tid);
        }
        
        // 7. random(t)
        randomWait();
        
        // 8. unlock(y)
        if (resource_y.isLockedBy(tid)) {
            resource_y.unlock(tid);
        }
        
        // 9. random(t)
        randomWait();
        
        // 10. commit(t)
        print("Thread T({}) finaliza sua execução (COMMIT)\n", .{tid});
        break;
    }
}

fn deadlockMonitor(_: *void) void {
    while (true) {
        std.time.sleep(1000 * 1000000); 
        const tid = deadlock_detector.detectAndResolve();
        if (tid != null)
            should_terminate[tid.?] = true;

    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("=== SIMULADOR DE CONTROLE DE CONCORRÊNCIA COM DEADLOCK ===\n", .{});
    print("Iniciando {} threads concorrentes...\n\n", .{NUM_THREADS});
    
    resource_x = Resource.init(allocator, "X");
    resource_y = Resource.init(allocator, "Y");
    defer resource_x.deinit();
    defer resource_y.deinit();
    
    for (&transactions, 0..) |*transaction, i| {
        transaction.* = Transaction.init(@intCast(i));
    }
    
    var resources = [_]*Resource{ &resource_x, &resource_y };
    deadlock_detector = DeadlockDetector.init(&transactions, &resources);
    
    var monitor_data: void = {};
    const monitor_thread = try Thread.spawn(.{}, deadlockMonitor, .{&monitor_data});
    
    var threads: [NUM_THREADS]Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try Thread.spawn(.{}, transactionFunction, .{&transactions[i]});
        transactions[i].thread_handle = thread.*;
    }
    
    for (threads) |thread| {
        thread.join();
    }
    
    monitor_thread.detach();
    
    print("\n=== SIMULAÇÃO CONCLUÍDA ===\n", .{});
}
