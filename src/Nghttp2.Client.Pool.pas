unit Nghttp2.Client.Pool;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// ============================================================================
//  Nghttp2.Client.Pool  (CL5 - reusable session pool)
//
//  A thread-safe pool of TNghttp2Client connections, keyed by
//  scheme(TLS) + host + port, for callers that need more concurrency than one
//  HTTP/2 connection's multiplexing provides, or that drive requests from
//  several threads.
//
//  Model (acquire / release):
//    var P: TNghttp2ClientPool;
//    var C: TNghttp2Client;
//    P := TNghttp2ClientPool.Create;
//    try
//      C := P.Acquire('127.0.0.1', 9010);   // connected, owned by THIS thread
//      try
//        R := C.SubmitRequest('GET', '/ping', nil, nil);
//      finally
//        P.Release(C);                        // back to the idle set
//      end;
//    finally
//      P.Free;
//    end;
//
//  Concurrency contract: a client handed out by Acquire belongs to exactly one
//  thread until Release. That satisfies libnghttp2's rule that only one thread
//  may ever drive a session - the pool never drives a client itself, it only
//  owns the idle set. The pool's own structures are guarded by a critical
//  section; a client's I/O never runs under that lock.
//
//  Ceiling: Acquire blocks (up to AcquireTimeoutMS) when MaxClientsPerKey
//  connections for the key are already in use, and raises ENghttp2ClientPool if
//  the budget expires. AcquireTimeoutMS = 0 fails fast instead of waiting. The
//  wait is a short bounded poll rather than a condition variable: FPC's SyncObjs
//  has no semaphore, and an auto-reset event collapses two near-simultaneous
//  releases into one wakeup, which would strand a waiter while a slot was free.
//
//  Idle eviction: a client idle for longer than IdleTimeoutMS is closed and
//  dropped. Eviction is lazy (checked for the key on each Acquire) and can be
//  forced across all keys with Sweep. IdleTimeoutMS = 0 disables it.
//
//  Health: on checkout the pool calls Client.Connect(host, port), which reuses
//  a live same-endpoint session and reopens one that received GOAWAY or was
//  torn down (CL4). A peer that closed an idle socket WITHOUT GOAWAY is not
//  detected here - the first request on such a client fails and the caller
//  retries; set a short IdleTimeoutMS to bound that window.
//
//  TLS: assign a TTlsClientContext to the pool's TlsContext property and pass
//  AUseTls := True to Acquire. The context is shared across the pool's TLS
//  clients (FIX-ALPN-RACE-1 made a shared client context safe) and is NOT owned
//  by the pool - free it after the pool.
//
//  FPC 3.2.2 clean: no inline var, no anonymous methods, no attributes.
// ============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  DateUtils,
  Generics.Collections,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  System.Generics.Collections,
{$IFEND}
  Nghttp2.Client,
  Nghttp2.Tls;

type
  ENghttp2ClientPool = class(Exception);

  TNghttp2ClientPoolConfig = record
    MaxClientsPerKey: Integer;   // ceiling of connections per scheme+host+port
    IdleTimeoutMS:    Integer;   // close a client idle longer than this; 0 = never
    AcquireTimeoutMS: Integer;   // wait budget at the ceiling; 0 = fail fast
    class function Default: TNghttp2ClientPoolConfig; static;
  end;

  // One pooled connection plus its bookkeeping. Owns its TNghttp2Client.
  TNghttp2PooledClient = class
  public
    Client:   TNghttp2Client;
    Key:      string;
    InUse:    Boolean;
    LastUsed: TDateTime;
    destructor Destroy; override;
  end;

  // [CL5.5 POOLSTATS-1] A consistent snapshot of the pool, read under one lock.
  // The first three are instantaneous (same values as TotalCount/IdleCount/
  // InUseCount); the rest are CUMULATIVE since the pool was created, the numbers
  // a concurrency problem is diagnosed from.
  TNghttp2ClientPoolStats = record
    Total:           Integer;   // connections the pool holds right now
    Idle:            Integer;   // of those, available to Acquire
    InUse:           Integer;   // of those, leased out
    Acquires:        Int64;     // successful Acquire calls
    AcquireWaits:    Int64;     // Acquires that had to wait at the ceiling
                                // (whether they then succeeded or timed out)
    WaitMS:          Int64;     // total milliseconds spent waiting at the ceiling
    MaxWaitMS:       Int64;     // the longest single ceiling wait
    Evictions:       Int64;     // idle clients closed + dropped (lazy or Sweep)
    ConnectFailures: Int64;     // Acquire calls whose Connect raised
  end;

  TNghttp2ClientPool = class
  private
    FLock:       TCriticalSection;
    FEntries:    TList<TNghttp2PooledClient>;   // non-owning; entries freed by hand
    FConfig:     TNghttp2ClientPoolConfig;
    FTlsContext: TTlsClientContext;   // not owned
    // [CL5.5 POOLSTATS-1] cumulative counters, all touched only under FLock.
    FStatAcquires:        Int64;
    FStatAcquireWaits:    Int64;
    FStatWaitMS:          Int64;
    FStatMaxWaitMS:       Int64;
    FStatEvictions:       Int64;
    FStatConnectFailures: Int64;
    function  MakeKey(const AHost: string; APort: Word; AUseTls: Boolean): string;
    // All of these run WITH FLock held.
    function  CountForKeyLocked(const AKey: string): Integer;
    function  TakeIdleLocked(const AKey: string): TNghttp2PooledClient;
    procedure ExtractIdleVictimsLocked(const AKey: string;
      AOnlyKey: Boolean; AVictims: TList<TNghttp2PooledClient>);
    function  CountLocked(AInUse: Boolean): Integer;
    procedure RecordWaitLocked(AWaitStart: TDateTime);
  public
    constructor Create; overload;
    constructor Create(const AConfig: TNghttp2ClientPoolConfig); overload;
    destructor  Destroy; override;

    // Returns a connected client owned by the calling thread until Release.
    function  Acquire(const AHost: string; APort: Word;
      AUseTls: Boolean = False): TNghttp2Client;
    // Returns a client taken from Acquire to the idle set. Raises if the client
    // did not come from this pool.
    procedure Release(AClient: TNghttp2Client);

    // Close and drop every idle client older than IdleTimeoutMS, across all keys.
    procedure Sweep;

    // Observability (for gates and metrics).
    function  TotalCount: Integer;
    function  IdleCount: Integer;
    function  InUseCount: Integer;
    // [CL5.5 POOLSTATS-1] a consistent cumulative + instantaneous snapshot.
    function  Stats: TNghttp2ClientPoolStats;

    property TlsContext: TTlsClientContext read FTlsContext write FTlsContext;
  end;

implementation

const
  DEFAULT_MAX_CLIENTS_PER_KEY = 8;
  DEFAULT_IDLE_TIMEOUT_MS     = 30000;
  DEFAULT_ACQUIRE_TIMEOUT_MS  = 30000;
  CEILING_POLL_MS             = 10;   // retry granularity while at the ceiling

{ TNghttp2ClientPoolConfig }

class function TNghttp2ClientPoolConfig.Default: TNghttp2ClientPoolConfig;
begin
  Result.MaxClientsPerKey := DEFAULT_MAX_CLIENTS_PER_KEY;
  Result.IdleTimeoutMS    := DEFAULT_IDLE_TIMEOUT_MS;
  Result.AcquireTimeoutMS := DEFAULT_ACQUIRE_TIMEOUT_MS;
end;

{ TNghttp2PooledClient }

destructor TNghttp2PooledClient.Destroy;
begin
  // Client may be nil if construction failed before assignment.
  if Client <> nil then
    Client.Free;
  inherited;
end;

{ TNghttp2ClientPool }

constructor TNghttp2ClientPool.Create;
begin
  Create(TNghttp2ClientPoolConfig.Default);
end;

constructor TNghttp2ClientPool.Create(const AConfig: TNghttp2ClientPoolConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.MaxClientsPerKey < 1 then
    FConfig.MaxClientsPerKey := 1;
  FLock := TCriticalSection.Create;
  FEntries := TList<TNghttp2PooledClient>.Create;
  FTlsContext := nil;
end;

destructor TNghttp2ClientPool.Destroy;
var
  I: Integer;
begin
  // Nothing should be acquired at this point. Free each entry (its destructor
  // disconnects and frees the client), then the list itself.
  if FEntries <> nil then
  begin
    for I := 0 to FEntries.Count - 1 do
      FEntries[I].Free;
    FEntries.Free;
  end;
  if FLock <> nil then
    FLock.Free;
  inherited;
end;

function TNghttp2ClientPool.MakeKey(const AHost: string; APort: Word;
  AUseTls: Boolean): string;
var
  LScheme: string;
begin
  if AUseTls then
    LScheme := 'https'
  else
    LScheme := 'http';
  // Host lower-cased so the key is stable; brackets/IPv6 are left as given to
  // Connect, which resolves them.
  Result := LScheme + '|' + LowerCase(AHost) + '|' + IntToStr(APort);
end;

function TNghttp2ClientPool.CountForKeyLocked(const AKey: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FEntries.Count - 1 do
    if FEntries[I].Key = AKey then
      Inc(Result);
end;

function TNghttp2ClientPool.CountLocked(AInUse: Boolean): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FEntries.Count - 1 do
    if FEntries[I].InUse = AInUse then
      Inc(Result);
end;

function TNghttp2ClientPool.TakeIdleLocked(const AKey: string): TNghttp2PooledClient;
var
  I: Integer;
  LEntry: TNghttp2PooledClient;
begin
  Result := nil;
  for I := 0 to FEntries.Count - 1 do
  begin
    LEntry := FEntries[I];
    if (not LEntry.InUse) and (LEntry.Key = AKey) then
    begin
      LEntry.InUse := True;
      Result := LEntry;
      Exit;
    end;
  end;
end;

procedure TNghttp2ClientPool.ExtractIdleVictimsLocked(const AKey: string;
  AOnlyKey: Boolean; AVictims: TList<TNghttp2PooledClient>);
var
  I: Integer;
  LEntry: TNghttp2PooledClient;
begin
  if FConfig.IdleTimeoutMS <= 0 then
    Exit;
  // Walk downwards so Delete does not disturb the indices still to visit.
  for I := FEntries.Count - 1 downto 0 do
  begin
    LEntry := FEntries[I];
    if LEntry.InUse then
      Continue;
    if AOnlyKey and (LEntry.Key <> AKey) then
      Continue;
    if MilliSecondsBetween(Now, LEntry.LastUsed) >= FConfig.IdleTimeoutMS then
    begin
      // Remove the pointer (TList never frees); the caller frees the entry
      // outside the lock so teardown never blocks another thread.
      AVictims.Add(LEntry);
      FEntries.Delete(I);
      Inc(FStatEvictions);   // [CL5.5 POOLSTATS-1] run under FLock by the caller
    end;
  end;
end;

function TNghttp2ClientPool.Acquire(const AHost: string; APort: Word;
  AUseTls: Boolean): TNghttp2Client;
var
  LKey:      string;
  LEntry:    TNghttp2PooledClient;
  LVictims:  TList<TNghttp2PooledClient>;
  LDeadline: TDateTime;
  LAtCeiling: Boolean;
  LNew:      Boolean;
  I:         Integer;
  LWaited:    Boolean;     { [CL5.5 POOLSTATS-1] did this Acquire wait at the ceiling? }
  LWaitStart: TDateTime;   { [CL5.5 POOLSTATS-1] when the first ceiling wait began }
begin
  LKey := MakeKey(AHost, APort, AUseTls);
  LDeadline := IncMilliSecond(Now, FConfig.AcquireTimeoutMS);
  LWaited := False;
  LWaitStart := 0;
  LVictims := TList<TNghttp2PooledClient>.Create;
  try
    while True do
    begin
      LEntry := nil;
      LNew := False;
      LAtCeiling := False;

      FLock.Enter;
      try
        ExtractIdleVictimsLocked(LKey, True, LVictims);

        LEntry := TakeIdleLocked(LKey);
        if LEntry = nil then
        begin
          if CountForKeyLocked(LKey) < FConfig.MaxClientsPerKey then
          begin
            // Reserve a slot now, under the lock, so the ceiling is honoured
            // while we connect outside it.
            LEntry := TNghttp2PooledClient.Create;
            LEntry.Key := LKey;
            LEntry.InUse := True;
            LEntry.LastUsed := Now;
            FEntries.Add(LEntry);
            LNew := True;
          end
          else
            LAtCeiling := True;
        end;
      finally
        FLock.Leave;
      end;

      // Free evicted clients outside the lock (snapshot-then-free).
      for I := 0 to LVictims.Count - 1 do
        LVictims[I].Free;
      LVictims.Clear;

      if LEntry <> nil then
      begin
        // Connect OUTSIDE the lock. For a reused client Connect is a no-op when
        // the session is alive, and reopens it after GOAWAY/teardown.
        try
          if LNew then
            LEntry.Client := TNghttp2Client.Create;
          if AUseTls then
            LEntry.Client.TlsContext := FTlsContext
          else
            LEntry.Client.TlsContext := nil;
          LEntry.Client.Connect(AHost, APort);
        except
          // Connect failed: drop the reservation and re-raise. A waiter at the
          // ceiling re-checks on its next poll, so no wakeup is needed.
          FLock.Enter;
          try
            FEntries.Remove(LEntry);
            Inc(FStatConnectFailures);   // [CL5.5 POOLSTATS-1]
          finally
            FLock.Leave;
          end;
          LEntry.Free;
          raise;
        end;
        { [CL5.5 POOLSTATS-1] A connection is in hand: count the acquire, and the
          wait if we had to poll at the ceiling for it. }
        FLock.Enter;
        try
          Inc(FStatAcquires);
          if LWaited then
            RecordWaitLocked(LWaitStart);
        finally
          FLock.Leave;
        end;
        Result := LEntry.Client;
        Exit;
      end;

      if LAtCeiling then
      begin
        if (FConfig.AcquireTimeoutMS <= 0) or (Now >= LDeadline) then
        begin
          { [CL5.5 POOLSTATS-1] A wait that ended in saturation is still a wait -
            record it before raising, so WaitMS reflects it too. }
          if LWaited then
          begin
            FLock.Enter;
            try
              RecordWaitLocked(LWaitStart);
            finally
              FLock.Leave;
            end;
          end;
          raise ENghttp2ClientPool.CreateFmt(
            'Nghttp2ClientPool: no connection available for %s within %d ms ' +
            '(MaxClientsPerKey=%d all in use).',
            [LKey, FConfig.AcquireTimeoutMS, FConfig.MaxClientsPerKey]);
        end;
        { [CL5.5 POOLSTATS-1] Mark the wait on the first poll only, so WaitMS
          measures the whole ceiling wait rather than one poll interval. }
        if not LWaited then
        begin
          LWaited := True;
          LWaitStart := Now;
        end;
        // Bounded poll, then retry the lock section, which re-reads real state
        // (a freed slot is always observed within one poll interval). Sleep is
        // SysUtils.Sleep on FPC and the portable TThread.Sleep on Delphi.
{$IF DEFINED(FPC)}
        Sleep(CEILING_POLL_MS);
{$ELSE}
        TThread.Sleep(CEILING_POLL_MS);
{$IFEND}
      end;
    end;
  finally
    LVictims.Free;
  end;
end;

procedure TNghttp2ClientPool.Release(AClient: TNghttp2Client);
var
  I: Integer;
  LEntry: TNghttp2PooledClient;
  LFound: Boolean;
begin
  if AClient = nil then
    Exit;
  LFound := False;
  FLock.Enter;
  try
    for I := 0 to FEntries.Count - 1 do
    begin
      LEntry := FEntries[I];
      if LEntry.Client = AClient then
      begin
        LEntry.InUse := False;
        LEntry.LastUsed := Now;
        LFound := True;
        Break;
      end;
    end;
  finally
    FLock.Leave;
  end;
  if not LFound then
    raise ENghttp2ClientPool.Create(
      'Nghttp2ClientPool.Release: client was not acquired from this pool.');
end;

procedure TNghttp2ClientPool.Sweep;
var
  LVictims: TList<TNghttp2PooledClient>;
  I: Integer;
begin
  LVictims := TList<TNghttp2PooledClient>.Create;
  try
    FLock.Enter;
    try
      ExtractIdleVictimsLocked('', False, LVictims);
    finally
      FLock.Leave;
    end;
    for I := 0 to LVictims.Count - 1 do
      LVictims[I].Free;
  finally
    LVictims.Free;
  end;
end;

function TNghttp2ClientPool.TotalCount: Integer;
begin
  FLock.Enter;
  try
    Result := FEntries.Count;
  finally
    FLock.Leave;
  end;
end;

function TNghttp2ClientPool.IdleCount: Integer;
begin
  FLock.Enter;
  try
    Result := CountLocked(False);
  finally
    FLock.Leave;
  end;
end;

function TNghttp2ClientPool.InUseCount: Integer;
begin
  FLock.Enter;
  try
    Result := CountLocked(True);
  finally
    FLock.Leave;
  end;
end;

{ [CL5.5 POOLSTATS-1] Caller holds FLock. Fold one completed ceiling wait into
  the counters. MilliSecondsBetween returns Int64, so a long wait does not wrap. }
procedure TNghttp2ClientPool.RecordWaitLocked(AWaitStart: TDateTime);
var
  LMS: Int64;
begin
  LMS := MilliSecondsBetween(Now, AWaitStart);
  Inc(FStatAcquireWaits);
  Inc(FStatWaitMS, LMS);
  if LMS > FStatMaxWaitMS then
    FStatMaxWaitMS := LMS;
end;

function TNghttp2ClientPool.Stats: TNghttp2ClientPoolStats;
begin
  FLock.Enter;
  try
    Result.Total           := FEntries.Count;
    Result.Idle            := CountLocked(False);
    Result.InUse           := CountLocked(True);
    Result.Acquires        := FStatAcquires;
    Result.AcquireWaits    := FStatAcquireWaits;
    Result.WaitMS          := FStatWaitMS;
    Result.MaxWaitMS       := FStatMaxWaitMS;
    Result.Evictions       := FStatEvictions;
    Result.ConnectFailures := FStatConnectFailures;
  finally
    FLock.Leave;
  end;
end;

end.
