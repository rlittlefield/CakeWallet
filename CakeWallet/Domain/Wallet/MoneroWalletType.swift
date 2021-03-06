//
//  MoneroWalletType.swift
//  CakeWallet
//
//  Created by FotoLockr on 31.01.2018.
//  Copyright © 2018 FotoLockr. All rights reserved.
//

import Foundation
import PromiseKit

let moneroBlockSize = 1000
private let updateQueue = DispatchQueue(label: "com.fotolockr.com.cakewallet.updateQueue", qos: .background)

final class MoneroWalletType: WalletProtocol {
    var name: String {
        return moneroAdapter.name()
    }
    
    var balance: Amount {
        return MoneroAmount(value: moneroAdapter.balance())
    }
    
    var unlockedBalance: Amount {
        return MoneroAmount(value: moneroAdapter.unlockedBalance())
    }
    
    var address: String {
        return moneroAdapter.address()
    }
    
    var seed: String {
        return moneroAdapter.seed()
    }
    
    var isConnected: Bool {
        return moneroAdapter.connectionStatus() == 1
    }
    
    var isUpdateStarted: Bool {
        switch status {
        case .startUpdating, .updated, .updating(_):
            return true
        default:
            return false
        }
    }
    
    var isReadyToReceive: Bool {
        if case .updated = status {
            return true
        } else if isNew && !isRecovery {
            return false
        } else {
            return true
        }
    }
    
    private(set) var currentHeight: UInt64
    var status: NetworkStatus {
        didSet {
            self.emit(.changedStatus(status))
            
            if case NetworkStatus.updated = status {
                if isNew {
                    isNew = false
                }
            }
        }
    }
    
    private(set) var isNew: Bool {
        didSet {
            do {
                try self.keychainStorage.set(
                    value: isNew.description,
                    forKey: KeychainKey.isNew(WalletIndex(name: name)))
                self.emit(.changedIsNew(isNew))
            } catch {
                print(error.localizedDescription)
            }
        }
    }
    
    private(set) var isRecovery: Bool
    private var password: String
    private var listeners: [ChangeHandler]
    private var _moneroTransactionHistory: MoneroTransactionHistory?
    private let moneroAdapter: MoneroWalletAdapter
    private let keychainStorage: KeychainStorage
    
    init(moneroAdapter: MoneroWalletAdapter, password: String, isRecovery: Bool, keychainStorage: KeychainStorage) {
        self.moneroAdapter = moneroAdapter
        self.currentHeight = 0
        self.password = password
        self.isRecovery = isRecovery
        self.keychainStorage = keychainStorage
        listeners = []
        status = .notConnected
        isNew = true
        
        if
            let isNewStr = try? self.keychainStorage.fetch(forKey: .isNew(WalletIndex(name: name))),
            let isNew = Bool(isNewStr) {
            self.isNew = isNew
        }
        
        moneroAdapter.delegate = self
    }
    
    func save() -> Promise<Void> {
        return Promise { fulfill, reject in
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.moneroAdapter.save()
                    fulfill(())
                } catch {
                    reject(error)
                }
            }
        }
    }
    
    func connect(withSettings settings: ConnectionSettings, updateState: Bool) -> Promise<Void> {
        return Promise { fulfill, reject in
            DispatchQueue.global(qos: .background).async {
                do {
                    if updateState {
                        self.status = .connecting
                    }
                    
                    self.moneroAdapter.setDaemonAddress(settings.uri, login: settings.login, password: settings.password)
                    try self.moneroAdapter.connectToDaemon()
                    
                    if updateState {
                        self.status = .connected
                    }
                    
                    fulfill(())
                } catch {
                    if updateState {
                        self.status = .notConnected
                    }
                    
                    reject(error)
                }
            }
        }
    }
    
    func authenticatePassword(_ password: String) -> Bool {
        return self.password == password
    }
    
    func changePassword(oldPassword: String, newPassword: String) -> Promise<Void> {
        return Promise { fulfill, reject in
            guard authenticatePassword(oldPassword) else {
                throw WalletError.incorrectPassword
            }
            
            DispatchQueue.global(qos: .background).async {
                do {
                    try self.moneroAdapter.setPassword(newPassword)
                    self.password = newPassword
                    fulfill(())
                } catch {
                    reject(error)
                }
            }
        }
    }
    
    func close() {
        // Hardcode value: always save wallet on close.
        self.moneroAdapter.close(true)
    }
    
    func createTransaction(to address: String, withPaymentId paymentId: String,
                           amount: Amount, priority: TransactionPriority) -> Promise<PendingTransaction> {
        return Promise { fulfill, reject in
            DispatchQueue.global(qos: .background).async {
                do {
                    let priorityRaw = priority.rawValue
                    let moneroPendingTransactionAdapter = try self.moneroAdapter.createTransaction(
                        toAddress: address,
                        withPaymentId: paymentId,
                        amountStr: amount.formatted(),
                        priority: priorityRaw)
                    let moneroPendingTransaction = MoneroPendingTransaction(moneroPendingTransactionAdapter: moneroPendingTransactionAdapter)
                    fulfill(moneroPendingTransaction)
                } catch let error as NSError {
                    if let transactionError = TransactionError(from: error, amount: amount, balance: self.balance) {
                        reject(transactionError)
                    } else {
                        reject(error)
                    }
                }
            }
        }
    }
    
    func startUpdate() {
        updateQueue.async {
            if !self.isUpdateStarted {
                self.status = .startUpdating
            }
            
            self.moneroAdapter.startRefreshAsync()
        }
    }
    
    func observe(_ handler: @escaping ObservableWallet.ChangeHandler) {
        listeners.append(handler)
        handler(.reset, self)
    }
    
    func transactionHistory() -> TransactionHistory {
        if let moneroTransactionHistory = _moneroTransactionHistory {
            moneroTransactionHistory.refresh()
            return moneroTransactionHistory
        }
        
        let moneroTransactionHistory = MoneroTransactionHistory(
            moneroWalletHistoryAdapter: MoneroWalletHistoryAdapter(wallet: moneroAdapter))
        _moneroTransactionHistory = moneroTransactionHistory
        moneroTransactionHistory.refresh()
        return moneroTransactionHistory
    }
    
    func fetchBlockChainHeight() -> UInt64 {
//        let now = Date().timeIntervalSince1970
//
//        if (_cachedBlockChainHeight == 0 ||
//            currentHeight > _cachedBlockChainHeight ||
//            now - blockChainHeightUpdateInterval > 60) {
//            _cachedBlockChainHeight = moneroAdapter.daemonBlockChainHeight()
//            blockChainHeightUpdateInterval = now
//        }
        
        return moneroAdapter.daemonBlockChainHeight()
    }
    
    private func emit(_ change: MoneroWalletChange) {
        listeners.forEach { $0(change, self) }
    }
}

extension MoneroWalletType: MoneroWalletAdapterDelegate {
    func newBlock(_ block: UInt64) {
        self.currentHeight = block
        let newBlock = Block(height: block)
        let blockchainHeight = self.fetchBlockChainHeight()
        let progress = { () -> Float in
            let _diff = Float(block) / Float(blockchainHeight)
            return _diff > 1.00 ? 1.00 : _diff
        }()
        let updatingProgress = UpdatingProgress(block: newBlock, progress: progress)
        
        
        switch status {
        case .notConnected, .failedConnection(_):
            return
        default:
            break
        }
        
        if case .updating = self.status {} else {
            status = .startUpdating
        }
        
        updateQueue.async {
            self.status = .updating(updatingProgress)
        }
    }
    
    func refreshed() {
        updateQueue.async {
            let blockChainHeight = self.fetchBlockChainHeight()
            let diff: Int = Int(blockChainHeight) - Int(self.currentHeight)
            self.emit(.changedBalance(self.balance))
            self.emit(.changedUnlockedBalance(self.unlockedBalance))
            
            switch self.status {
            case .failedConnection(_), .notConnected, .connecting:
                break
            default:
                if diff == blockChainHeight {
                    self.currentHeight = blockChainHeight
                    self.status = .updated
                    _ = self.save()
                    return
                }
            }
            
            switch self.status {
            case .updating(_), .startUpdating:
                if diff <= moneroBlockSize {
                    self.status = .updated
                    _ = self.save()
                }
            default:
                break
            }
        }
    }
    
    func updated() {
        self.emit(.changedBalance(balance))
        self.emit(.changedUnlockedBalance(unlockedBalance))
    }
    
    func moneyReceived(_ txId: String!, amount: UInt64) {
        emit(.changedBalance(balance))
        emit(.changedUnlockedBalance(unlockedBalance))
    }
    
    func moneySpent(_ txId: String!, amount: UInt64) {
        emit(.changedBalance(balance))
        emit(.changedUnlockedBalance(unlockedBalance))
    }
    
    func unconfirmedMoneyReceived(_ txId: String!, amount: UInt64) {
        emit(.changedBalance(balance))
        emit(.changedUnlockedBalance(unlockedBalance))
    }
}
