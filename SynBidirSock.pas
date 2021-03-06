/// implements bidirectional client and server protocol, e.g. WebSockets
// - this unit is a part of the freeware Synopse mORMot framework,
// licensed under a MPL/GPL/LGPL tri-license; version 1.18
unit SynBidirSock;

{
    This file is part of the Synopse framework.

    Synopse framework. Copyright (C) 2015 Arnaud Bouchez
      Synopse Informatique - http://synopse.info

  *** BEGIN LICENSE BLOCK *****
  Version: MPL 1.1/GPL 2.0/LGPL 2.1

  The contents of this file are subject to the Mozilla Public License Version
  1.1 (the "License"); you may not use this file except in compliance with
  the License. You may obtain a copy of the License at
  http://www.mozilla.org/MPL

  Software distributed under the License is distributed on an "AS IS" basis,
  WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
  for the specific language governing rights and limitations under the License.

  The Original Code is Synopse mORMot framework.

  The Initial Developer of the Original Code is Arnaud Bouchez.

  Portions created by the Initial Developer are Copyright (C) 2015
  the Initial Developer. All Rights Reserved.

  Contributor(s):


  Alternatively, the contents of this file may be used under the terms of
  either the GNU General Public License Version 2 or later (the "GPL"), or
  the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
  in which case the provisions of the GPL or the LGPL are applicable instead
  of those above. If you wish to allow use of your version of this file only
  under the terms of either the GPL or the LGPL, and not to allow others to
  use your version of this file under the terms of the MPL, indicate your
  decision by deleting the provisions above and replace them with the notice
  and other provisions required by the GPL or the LGPL. If you do not delete
  the provisions above, a recipient may use your version of this file under
  the terms of any one of the MPL, the GPL or the LGPL.

  ***** END LICENSE BLOCK *****

  Version 1.18
  - first public release, corresponding to mORMot Framework 1.18


   TODO: add TWebSocketClientRequest with the possibility to
   - broadcast a message to several aCallingThread: THttpServerResp values
   - send asynchronously (e.g. for SOA methods sending events with no result)

   TODO: enhance TWebSocketServer process to use events, and not threads
   - current implementation has its threads spending most time waiting in loops
   - eventually also at SynCrtSock's THttpServer class level also


}

{$I Synopse.inc} // define HASINLINE USETYPEINFO CPU32 CPU64 OWNNORMTOUPPER

interface

uses
  {$ifdef MSWINDOWS}
  Windows,
  {$else}
  {$ifdef KYLIX3}
  LibC,
  Types,
  SynKylix,
  {$endif}
  {$ifdef FPC}
  SynFPCLinux,
  {$endif}
  {$endif}
  SysUtils,
  Classes,
  Contnrs,
  SyncObjs,
  SynLZ,
  SynCommons,
  SynLog,
  SynCrtSock,
  SynCrypto;


type
  /// Exception raised from this unit
  ESynBidirSocket = class(ESynException);


{ -------------- WebSockets shared classes for bidirectional remote access }

type
  /// defines the interpretation of the WebSockets frame data
  TWebSocketFrameOpCode = (
    focContinuation, focText, focBinary,
    focReserved3, focReserved4, focReserved5, focReserved6, focReserved7,
    focConnectionClose, focPing, focPong,
    focReservedB, focReservedC, focReservedD, focReservedE, focReservedF);

  /// set of WebSockets frame interpretation
  TWebSocketFrameOpCodes = set of TWebSocketFrameOpCode;

  /// stores a WebSockets frame
  // - see @http://tools.ietf.org/html/rfc6455 for reference
  TWebSocketFrame = record
    /// the interpretation of the frame data
    opcode: TWebSocketFrameOpCode;
    /// the frame data itself
    // - is plain UTF-8 for focText kind of frame
    // - is raw binary for focBinary or any other frames
    payload: RawByteString;
  end;

  /// points to a WebSockets frame
  PWebSocketFrame = ^TWebSocketFrame;

  /// a dynamic list of WebSockets frames
  TWebSocketFrameDynArray = array of TWebSocketFrame;

  {$M+}
  TWebSocketProcess = class;
  {$M-}

  /// handle an application-level WebSockets protocol
  // - shared by TWebSocketServer and TWebSocketClient classes
  // - once upgraded to WebSockets, a HTTP link could be used e.g. to transmit our
  // proprietary 'synopsejson' or 'synopsebinary' application content, as stated
  // by this typical handshake:
  // $ GET /myservice HTTP/1.1
  // $ Host: server.example.com
  // $ Upgrade: websocket
  // $ Connection: Upgrade
  // $ Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==
  // $ Sec-WebSocket-Protocol: synopsejson
  // $ Sec-WebSocket-Version: 13
  // $ Origin: http://example.com
  // $
  // $ HTTP/1.1 101 Switching Protocols
  // $ Upgrade: websocket
  // $ Connection: Upgrade
  // $ Sec-WebSocket-Accept: HSmrc0sMlYUkAGmm5OPpG2HaGWk=
  // $ Sec-WebSocket-Protocol: synopsejson
  // - the TWebSocketProtocolJSON inherited class will implement
  // $ Sec-WebSocket-Protocol: synopsejson
  // - the TWebSocketProtocolBinary inherited class will implement
  // $ Sec-WebSocket-Protocol: synopsebinary
  TWebSocketProtocol = class(TSynPersistent)
  protected
    fName: RawUTF8;
    fURI: RawUTF8;
    procedure ProcessIncomingFrame(Sender: TWebSocketProcess;
      var request: TWebSocketFrame); virtual; abstract;
    function SendFrames(Owner: TWebSocketProcess;
      var Frames: TWebSocketFrameDynArray; var FramesCount: integer): boolean; virtual;
    function FrameIs(const frame: TWebSocketFrame; const Head: RawUTF8): boolean; virtual; 
    function FrameType(const frame: TWebSocketFrame): RawUTF8; virtual;
  public
    /// abstract constructor to initialize the protocol
    // - the protocol should be named, so that the client may be able to request
    // for a given protocol
    // - if aURI is '', any URI would potentially upgrade to this protocol; you can
    // specify an URI to limit the protocol upgrade to a single resource
    constructor Create(const aName,aURI: RawUTF8); reintroduce;
    /// compute a new instance of the WebSockets protocol, with same parameters
    function Clone: TWebSocketProtocol; virtual; abstract;
  published
    /// the Sec-WebSocket-Protocol application name currently involved
    // - is currently 'synopsejson' or 'synopsebinary'
    property Name: RawUTF8 read fName;
    /// the optional URI on which this protocol would be enabled
    // - leave to '' if any URI should match
    property URI: RawUTF8 read fURI;
  end;

  /// callback event triggered by TWebSocketProtocolChat for any incoming message
  // - a first call with frame.opcode=focContinuation will take place when
  // the connection will be upgrade to WebSockets
  // - then any incoming focText/focBinary events will trigger this callback
  // - eventually, a focConnectionClose will notify the connection ending
  TOnWebSocketProtocolChatIncomingFrame =
    procedure(Sender: THttpServerResp; const Frame: TWebSocketFrame) of object;

  /// simple chatting protocol, allowing to receive and send WebSocket frames
  // - you can use this protocol to implement simple asynchronous communication
  // with events expecting no answers, e.g. with AJAX applications
  // - see TWebSocketProtocolRest for bi-directional events expecting answers
  TWebSocketProtocolChat = class(TWebSocketProtocol)
  protected
    fOnIncomingFrame: TOnWebSocketProtocolChatIncomingFrame;
    procedure ProcessIncomingFrame(Sender: TWebSocketProcess;
      var request: TWebSocketFrame); override;
  public
    /// compute a new instance of the WebSockets protocol, with same parameters
    function Clone: TWebSocketProtocol; override;
    /// on the server side, allows to send a message over the wire to a
    // specified client connection
    function SendFrame(Sender: THttpServerResp; const Frame: TWebSocketFrame): boolean;
    /// you can assign an event to this property to be notified of incoming messages
    property OnIncomingFrame: TOnWebSocketProtocolChatIncomingFrame
      read fOnIncomingFrame write fOnIncomingFrame;
  end;

  /// handle a REST application-level bi-directional WebSockets protocol
  // - will emulate a bi-directional REST process, using THttpServerRequest to
  // store and handle the request parameters: clients would be able to send
  // regular REST requests to the server, but the server could use the same
  // communication channel to push REST requests to the client
  // - a local THttpServerRequest will be used on both client and server sides,
  // to store REST parameters and compute the corresponding WebSockets frames
  TWebSocketProtocolRest = class(TWebSocketProtocol)
  protected
    procedure ProcessIncomingFrame(Sender: TWebSocketProcess;
      var request: TWebSocketFrame); override;
    procedure FrameCompress(const Values: array of RawByteString;
      const Content,ContentType: RawByteString; var frame: TWebSocketFrame); virtual; abstract;
    function FrameDecompress(const frame: TWebSocketFrame; const Head: RawUTF8;
      const values: array of PRawByteString; var contentType,content: RawByteString): Boolean; virtual; abstract;
    /// convert the input information of REST request to a WebSocket frame
    procedure InputToFrame(Ctxt: THttpServerRequest; aNoAnswer: boolean;
      out request: TWebSocketFrame); virtual;
    /// convert a WebSocket frame to the input information of a REST request
    function FrameToInput(var request: TWebSocketFrame; out aNoAnswer: boolean;
      Ctxt: THttpServerRequest): boolean; virtual;
    /// convert a WebSocket frame to the output information of a REST request
    function FrameToOutput(var answer: TWebSocketFrame; Ctxt: THttpServerRequest): cardinal; virtual;
    /// convert the output information of REST request to a WebSocket frame
    procedure OutputToFrame(Ctxt: THttpServerRequest; Status: Cardinal;
      out answer: TWebSocketFrame); virtual;
  end;

  /// used to store the class of a TWebSocketProtocol type
  TWebSocketProtocolClass = class of TWebSocketProtocol;

  /// handle a REST application-level WebSockets protocol using JSON for transmission
  // - could be used e.g. for AJAX or non Delphi remote access
  // - this class will implement then following application-level protocol:
  // $ Sec-WebSocket-Protocol: synopsejson
  TWebSocketProtocolJSON = class(TWebSocketProtocolRest)
  protected
    procedure FrameCompress(const Values: array of RawByteString;
      const Content,ContentType: RawByteString; var frame: TWebSocketFrame); override;
    function FrameDecompress(const frame: TWebSocketFrame; const Head: RawUTF8;
      const values: array of PRawByteString; var contentType,content: RawByteString): Boolean; override;
    function FrameIs(const frame: TWebSocketFrame; const Head: RawUTF8): boolean; override;
    function FrameType(const frame: TWebSocketFrame): RawUTF8; override;
  public
    /// compute a new instance of the WebSockets protocol, with same parameters
    function Clone: TWebSocketProtocol; override;
    /// initialize the WebSockets JSON protocol
    // - if aURI is '', any URI would potentially upgrade to this protocol; you can
    // specify an URI to limit the protocol upgrade to a single resource
    constructor Create(const aURI: RawUTF8); reintroduce;
  end;

  /// handle a REST application-level WebSockets protocol using compressed and
  // optionally AES-CFB encrypted binary
  // - this class will implement then following application-level protocol:
  // $ Sec-WebSocket-Protocol: synopsebinary
  TWebSocketProtocolBinary = class(TWebSocketProtocolRest)
  protected
    fEncryption: TAESAbstract;
    fCompressed: boolean;
    procedure FrameCompress(const Values: array of RawByteString;
      const Content,ContentType: RawByteString; var frame: TWebSocketFrame); override;
    function FrameDecompress(const frame: TWebSocketFrame; const Head: RawUTF8;
      const values: array of PRawByteString; var contentType,content: RawByteString): Boolean; override;
    function FrameIs(const frame: TWebSocketFrame; const Head: RawUTF8): boolean; override;
    function FrameType(const frame: TWebSocketFrame): RawUTF8; override;
    function SendFrames(Owner: TWebSocketProcess;
      var Frames: TWebSocketFrameDynArray; var FramesCount: integer): boolean; override;
    procedure ProcessIncomingFrame(Sender: TWebSocketProcess;
      var request: TWebSocketFrame); override;
  public
    /// compute a new instance of the WebSockets protocol, with same parameters
    function Clone: TWebSocketProtocol; override;
    /// finalize the encryption, if was used
    destructor Destroy; override;
    /// initialize the WebSockets binary protocol
    // - if aURI is '', any URI would potentially upgrade to this protocol; you can
    // specify an URI to limit the protocol upgrade to a single resource
    // - if aKeySize if 128, 192 or 256, AES-CFB encryption will be used on on this protocol
    constructor Create(const aURI: RawUTF8; const aKey; aKeySize: cardinal;
      aCompressed: boolean=true); reintroduce; overload;
    /// initialize the WebSockets binary protocol
    // - if aURI is '', any URI would potentially upgrade to this protocol; you
    // can specify an URI to limit the protocol upgrade to a single resource
    /// - AES-CFB 256 bit encryption will be enabled on this protocol if the
    // aKey parameter supplied, after been hashed using SHA-256 algorithm
    constructor Create(const aURI, aKey: RawUTF8; aCompressed: boolean=true); reintroduce; overload;
    /// defines if SynLZ compression is enabled during the transmission
    // - is set to TRUE by default
    property Compressed: boolean read fCompressed write fCompressed;
  end;

  /// used to maintain a list of websocket protocols (for the server side)
  TWebSocketProtocolList = class
  protected
    fProtocols: array of TWebSocketProtocol;
    function FindIndex(const aName,aURI: RawUTF8): integer;
  public
    /// add a protocol to the internal list
    // - returns TRUE on success
    // - if this protocol is already existing for this given name and URI,
    // returns FALSE: it is up to the caller to release aProtocol if needed
    function Add(aProtocol: TWebSocketProtocol): boolean;
    /// add once a protocol to the internal list
    // - if this protocol is already existing for this given name and URI, any
    // previous one will be released - so it may be confusing on a running server
    // - returns TRUE if the protocol was added for the first time, or FALSE
    // if the protocol has been replaced or is invalid (e.g. aProtocol=nil)
    function AddOnce(aProtocol: TWebSocketProtocol): boolean;
    /// erase a protocol from the internal list, specified by its name
    function Remove(const aProtocolName,aURI: RawUTF8): boolean;
    /// finalize the list storage
    destructor Destroy; override;
    /// create a new protocol instance, from the internal list
    function CloneByName(const aProtocolName, aURI: RawUTF8): TWebSocketProtocol;
    /// create a new protocol instance, from the internal list
    function CloneByURI(const aURI: RawUTF8): TWebSocketProtocol;
    /// how many protocols are stored
    function Count: integer;
  end;

  /// indicates which kind of process did occur in the main WebSockets loop
  TWebSocketProcessOne = (
    wspNone, wspPing, wspDone, wspAnswer, wspError, wspClosed);

  /// indicates how TWebSocketProcess.NotifyCallback() will work
  TWebSocketProcessNotifyCallback = (
    wscBlockWithAnswer, wscBlockWithoutAnswer, wscNonBlockWithoutAnswer);

  /// used to manage a thread-safe list of WebSockets frames
  TWebSocketFrameList = class(TSynCriticalSection)
  public
    /// low-level access to the WebSocket frames list
    List: TWebSocketFrameDynArray;
    /// current number of WebSocket frames in the list
    Count: integer;
    /// add a WebSocket frame in the list
    procedure Push(const frame: TWebSocketFrame);
    /// retrieve a WebSocket frame from the list, oldest first
    // - you should specify a frame type to search for, according to the
    // specified WebSockets protocl
    function Pop(protocol: TWebSocketProtocol;
      const head: RawUTF8; out frame: TWebSocketFrame): boolean;
  end;

  /// parameters to be used for WebSockets process
  TWebSocketProcessSettings = object
    /// time in milli seconds between each focPing commands sent to the other end
    // - default is 0, i.e. no automatic ping sending on client side, and
    // 20000, i.e. 20 seconds, on server side
    HeartbeatDelay: cardinal;
    /// maximum period time in milli seconds when ProcessLoop thread will stay
    // idle before checking for the next pending requests
    // - default is 500 ms, but you may put a lower value, if you expects e.g.
    // REST commands or NotifyCallback(wscNonBlockWithoutAnswer) to be processed
    // with a lower delay
    LoopDelay: cardinal;
    /// will close the connection after a given number of invalid Heartbeat sent
    // - when a Hearbeat is failed to be transmitted, the class will start
    // counting how many ping/pong did fail: when this property value is
    // reached, it will release and close the connection
    // - default value is 5
    DisconnectAfterInvalidHeartbeatCount: cardinal;
    /// how many milliseconds the callback notification should wait acquiring
    // the connection before failing
    // - defaut is 5000, i.e. 5 seconds
    CallbackAcquireTimeOutMS: cardinal;
    /// how many milliseconds the callback notification should wait for the
    // client to return its answer
    // - defaut is 30000, i.e. 30 seconds
    CallbackAnswerTimeOutMS: cardinal;
    /// will set the default values
    procedure SetDefaults;
  end;
  
  /// generic WebSockets process, used on both client or server sides
  TWebSocketProcess = class(TSynCriticalSection)
  protected
    fSocket: TCrtSocket;
    fIncoming: TWebSocketFrameList;
    fOutgoing: TWebSocketFrameList;
    fOwnerThread: TNotifiedThread;
    fState: (wpsCreate,wpsRun,wpsClose,wpsDestroy);
    fProtocol: TWebSocketProtocol;
    fMaskSentFrames: byte;
    fLastSocketTicks: Int64;
    fSettings: TWebSocketProcessSettings;
    fInvalidPingSendCount: cardinal;
    fProcessCount: integer;
    /// low level WebSockets framing protocol
    function GetFrame(out Frame: TWebSocketFrame; TimeOut: cardinal): boolean;
    function SendFrame(const Frame: TWebSocketFrame): boolean;
    /// methods run e.g. by TWebSocketServerRest.WebSocketProcessLoop
    procedure ProcessStart; virtual;
    procedure ProcessStop; virtual;
    function ProcessLoop: boolean; virtual;
    function ComputeContext(out RequestProcess: TOnHttpServerRequest): THttpServerRequest; virtual; abstract;
    function HiResDelay(timeout: cardinal): boolean;
    procedure Log(const frame: TWebSocketFrame; const aMethodName: RawUTF8;
      aEvent: TSynLogInfo=sllTrace); virtual;
    function LastPingDelay: Int64;
    procedure SetLastPingTicks;
    procedure SendPendingOutgoingFrames;
  public
    /// initialize the WebSockets process on a given connection
    // - the supplied TWebSocketProtocol will be owned by this instance
    // - other parameters should reflect the client or server expectations
    constructor Create(aSocket: TCrtSocket; aProtocol: TWebSocketProtocol;
      aOwner: TNotifiedThread; const aSettings: TWebSocketProcessSettings); virtual;
    /// finalize the context
    // - will release the TWebSocketProtocol associated instance
    destructor Destroy; override;
    /// will push a request or notification to the other end of the connection
    // - caller should set the aRequest with the outgoing parameters, and
    // optionally receive a response from the other end
    // - the request may be sent in blocking or non blocking mode
    // - returns the HTML status code (HTML_SUCCESS=200 for success)
    function NotifyCallback(aRequest: THttpServerRequest;
      aMode: TWebSocketProcessNotifyCallback): cardinal; virtual;
  published
    /// the Sec-WebSocket-Protocol application protocol currently involved
    // - TWebSocketProtocolJSON or TWebSocketProtocolBinary in the mORMot context
    // - could be nil if the connection is in standard HTTP/1.1 mode
    property Protocol: TWebSocketProtocol read fProtocol;
  end;


{ -------------- WebSockets Server classes for bidirectional remote access }

type
  {$M+}
  TWebSocketServerResp = class;
  {$M-}

  /// implements WebSockets process as used on server side
  TWebSocketProcessServer = class(TWebSocketProcess)
  protected
    fServerResp: TWebSocketServerResp;
    function ComputeContext(out RequestProcess: TOnHttpServerRequest): THttpServerRequest; override;
    procedure ProcessStart; override;
    procedure ProcessStop; override;
  end;

  /// an enhanced input/output structure used for HTTP and WebSockets requests
  // - this class will contain additional parameters used to maintain the
  // WebSockets execution context in overriden TWebSocketServer.Process method
  TWebSocketServerResp = class(THttpServerResp)
  protected
    fProcess: TWebSocketProcessServer;
    fSettings: TWebSocketProcessSettings;
  public
    /// initialize the context, associated to a HTTP/WebSockets server instance
    constructor Create(aServerSock: THttpServerSocket; aServer: THttpServer
       {$ifdef USETHREADPOOL}; aThreadPool: TSynThreadPoolTHttpServer{$endif}); override;
    /// push a notification to the client
    function NotifyCallback(Ctxt: THttpServerRequest; aMode: TWebSocketProcessNotifyCallback): cardinal; virtual;
    /// the Sec-WebSocket-Protocol application protocol currently involved
    // - TWebSocketProtocolJSON or TWebSocketProtocolBinary in the mORMot context
    // - could be nil if the connection is in standard HTTP/1.1 mode
    function WebSocketProtocol: TWebSocketProtocol;
  end;

  /// main HTTP/WebSockets server Thread using the standard Sockets API (e.g. WinSock)
  // - once upgraded to WebSockets from the client, this class is able to serve
  // any Sec-WebSocket-Protocol application content
  TWebSocketServer = class(THttpServer)
  protected
    fConnections: TObjectList;
    fProtocols: TWebSocketProtocolList;
    fSettings: TWebSocketProcessSettings;
    /// will validate the WebSockets handshake, then call WebSocketProcessLoop()
    function WebSocketProcessUpgrade(ClientSock: THttpServerSocket;
      Context: TWebSocketServerResp): boolean; virtual;
    /// overriden method which will recognize the WebSocket protocol handshake,
    // then run the whole bidirectional communication in its calling thread
    // - here aCallingThread is a THttpServerResp, and ClientSock.Headers
    // and ConnectionUpgrade properties should be checked for the handshake
    procedure Process(ClientSock: THttpServerSocket;
      aCallingThread: TNotifiedThread); override;
    /// identifies an incoming THttpServerResp as a valid TWebSocketServerResp
    function IsActiveWebSocket(CallingThread: TNotifiedThread): TWebSocketServerResp; virtual;
  public
    /// create a Server Thread, binded and listening on a port
    // - this constructor will raise a EHttpServer exception if binding failed
    // - due to the way how WebSockets works, one thread will be created
    // for any incoming connection
    // - note that this constructor will not register any protocol, so is
    // useless until you execute Protocols.Add()
    constructor Create(const aPort: SockString); reintroduce; overload; virtual;
    /// close the server
    destructor Destroy; override;
    /// access to the protocol list handled by this server
    property Protocols: TWebSocketProtocolList read fProtocols;
    /// the settings to be used for WebSockets process
    // - note that those parameters won't be propagated to existing connections 
    property WebSocketSettings: TWebSocketProcessSettings
      read fSettings write fSettings;
  end;

  /// main HTTP/WebSockets server Thread using the standard Sockets API (e.g. WinSock)
  // - once upgraded to WebSockets from the client, this class is able to serve
  // our proprietary Sec-WebSocket-Protocol: 'synopsejson' or 'synopsebinary'
  // application content, managing regular REST client-side requests and
  // also server-side push notifications
  // - once in 'synopse*' mode, the Request() method will be trigerred from
  // any incoming REST request from the client, and the OnCallback event
  // will be available to push a request from the server to the client
  TWebSocketServerRest = class(TWebSocketServer)
  protected
    fCallbackAcquireTimeOutMS: cardinal;
    fCallbackAnswerTimeOutMS: cardinal;
  public
    /// create a Server Thread, binded and listening on a port, with no
    // default WebSockets protocol
    // - you should call manually Protocols.Add() to register the expected protocols
    constructor Create(const aPort: SockString); override;
    /// create a Server Thread, binded and listening on a port, with our
    // 'synopsebinary' and optionally 'synopsejson' modes
    // - if aWebSocketsURI is '', any URI would potentially upgrade; you can
    // specify an URI to limit the protocol upgrade to a single resource
    // - TWebSocketProtocolBinary will always be registered by this constructor
    // - if the encryption key text is not '', TWebSocketProtocolBinary will
    // use AES-CFB 256 bits encryption
    // - if aWebSocketsAJAX is TRUE, it will also register TWebSocketProtocolJSON
    // so that AJAX applications would be able to connect to this server
    constructor Create(const aPort: SockString;
      const aWebSocketsURI, aWebSocketsEncryptionKey: RawUTF8;
      aWebSocketsAJAX: boolean=false); reintroduce; overload;
    /// defines the WebSockets protocols to be used for this Server
    // - i.e. 'synopsebinary' and optionally 'synopsejson' modes
    // - if aWebSocketsURI is '', any URI would potentially upgrade; you can
    // specify an URI to limit the protocol upgrade to a single resource
    // - TWebSocketProtocolBinary will always be registered by this constructor
    // - if the encryption key text is not '', TWebSocketProtocolBinary will
    // use AES-CFB 256 bits encryption
    // - if aWebSocketsAJAX is TRUE, it will also register TWebSocketProtocolJSON
    // so that AJAX applications would be able to connect to this server
    procedure WebSocketsEnable(const aWebSocketsURI, aWebSocketsEncryptionKey: RawUTF8;
      aWebSocketsAJAX: boolean=false; aWebSocketsCompressed: boolean=true);
    /// server can send a request back to the client, when the connection has
    // been upgraded to WebSocket
    // - InURL/InMethod/InContent properties are input parameters (InContentType
    // is ignored)
    // - OutContent/OutContentType/OutCustomHeader are output parameters
    // - CallingThread should be set to the client's Ctxt.CallingThread
    // value, so that the method could know which connnection is to be used -
    // it will return STATUS_NOTFOUND (404) if the connection is unknown
    // - result of the function is the HTTP error code (200 if OK, e.g.)
    function WebSocketsCallback(Ctxt: THttpServerRequest; aMode: TWebSocketProcessNotifyCallback): cardinal; virtual;
  published
    /// how many milliseconds the callback notification should wait acquiring
    // the connection before failing, in WebSockets mode
    // - defaut is 5000, i.e. 5 seconds
    property CallbackAcquireTimeOutMS: cardinal
      read fCallbackAcquireTimeOutMS write fCallbackAcquireTimeOutMS;
    /// how many milliseconds the callback notification should wait for the
    // client to return its answer, in WebSockets mode
    // - defaut is 30000, i.e. 30 seconds
    property CallbackAnswerTimeOutMS: cardinal
      read fCallbackAnswerTimeOutMS write fCallbackAnswerTimeOutMS;
  end;


/// used to return the text corresponding to a specified WebSockets frame data
function OpcodeText(opcode: TWebSocketFrameOpCode): PShortString;


{ -------------- WebSockets Client classes for bidirectional remote access }

type
  {$M+}
  THttpClientWebSockets = class;
  TWebSocketProcessClientThread = class;
  {$M-}

  /// implements WebSockets process as used on client side
  TWebSocketProcessClient = class(TWebSocketProcess)
  protected
    fClientThread: TWebSocketProcessClientThread;
    function ComputeContext(out RequestProcess: TOnHttpServerRequest): THttpServerRequest; override;
  public
    /// initialize the client process for a given THttpClientWebSockets
    constructor Create(aSender: THttpClientWebSockets; aProtocol: TWebSocketProtocol); reintroduce; virtual;
    /// finalize the process
    destructor Destroy; override;
  end;

  /// WebSockets processing thread used on client side
  // - will handle any incoming callback
  TWebSocketProcessClientThread = class(TNotifiedThread)
  protected
    fThreadState: (sCreate, sRun, sFinished, sClosed);
    fProcess: TWebSocketProcessClient;
    procedure Execute; override;
  public
    constructor Create(aProcess: TWebSocketProcessClient); reintroduce;
  end;

  /// Socket API based REST and HTTP/1.1 client, able to upgrade to WebSockets
  // - will implement regular HTTP/1.1 until WebSocketsUpgrade() is called
  THttpClientWebSockets = class(THttpClientSocket)
  protected
    fProcess: TWebSocketProcessClient;
    fSettings: TWebSocketProcessSettings;
    fRequestProcess: TOnHttpServerRequest;
  public
    /// common initialization of all constructors
    // - this overridden method will set the UserAgent with some default value
    constructor Create(aTimeOut: cardinal=10000); override;
    /// finalize the connection
    destructor Destroy; override;
    /// process low-level REST request, either on HTTP/1.1 or via WebSockets
    // - after WebSocketsUpgrade() call, will use WebSockets for the communication
    function Request(const url, method: SockString; KeepAlive: cardinal;
      const header, Data, DataType: SockString; retry: boolean): integer; override;
    /// upgrade the HTTP client connection to a specified WebSockets protocol
    // - i.e. 'synopsebinary' and optionally 'synopsejson' modes
    // - you may specify an URI to as expected by the server for upgrade
    // - if aWebSocketsAJAX equals default FALSE, it will register the
    // TWebSocketProtocolBinaryprotocol, with AES-CFB 256 bits encryption
    // if the encryption key text is not '' and optional SynLZ compression
    // - if aWebSocketsAJAX is TRUE, it will register the slower and less secure
    // TWebSocketProtocolJSON (to be used for AJAX debugging/test purposes only)
    // and aWebSocketsEncryptionKey/aWebSocketsCompression parameters won't be used
    // - will return '' on success, or an error message on failure
    function WebSocketsUpgrade(const aWebSocketsURI, aWebSocketsEncryptionKey: RawUTF8;
      aWebSocketsAJAX: boolean=false; aWebSocketsCompression: boolean=true): RawUTF8;
    /// the settings to be used for WebSockets process
    // - note that those parameters won't be propagated to existing connections
    property WebSocketSettings: TWebSocketProcessSettings
      read fSettings write fSettings;
    /// this event handler will be executed for any incoming push notification
    property CallbackRequestProcess: TOnHttpServerRequest
      read fRequestProcess write fRequestProcess;
  published
    /// the current WebSockets processing class
    // - equals nil for plain HTTP/1.1 mode
    // - points to the current WebSockets process instance, after a successful
    // WebSocketsUpgrade() call, so that you could use e.g. WebSockets.Protocol
    // to retrieve the protocol currently used
    property WebSockets: TWebSocketProcessClient read fProcess write fProcess;
  end;


var
  /// if set, will log all WebSockets raw information
  WebSocketLog: TSynLogClass;

  
implementation


{ -------------- WebSockets shared classes for bidirectional remote access }


type
  TThreadHook = class(TThread);

const
  STATUS_WEBSOCKETCLOSED = 0;

function OpcodeText(opcode: TWebSocketFrameOpCode): PShortString;
begin
  result := GetEnumName(TypeInfo(TWebSocketFrameOpCode),ord(opcode));
end;

{ TWebSocketProcessSettings }

procedure TWebSocketProcessSettings.SetDefaults;
begin
  HeartbeatDelay := 0;
  LoopDelay := 500;
  DisconnectAfterInvalidHeartbeatCount := 5;
  CallbackAcquireTimeOutMS := 5000;
  CallbackAnswerTimeOutMS := 5000;
end;


{ TWebSocketProtocol }

constructor TWebSocketProtocol.Create(const aName,aURI: RawUTF8);
begin
  fName := aName;
  fURI := aURI;
end;

function TWebSocketProtocol.FrameIs(const frame: TWebSocketFrame;
  const Head: RawUTF8): boolean;
begin
  result := false; // no frame type by default
end;

function TWebSocketProtocol.FrameType(
  const frame: TWebSocketFrame): RawUTF8;
begin
  result := ''; // no frame URI by default
end;

function TWebSocketProtocol.SendFrames(Owner: TWebSocketProcess;
  var Frames: TWebSocketFrameDynArray; var FramesCount: integer): boolean;
var i,n: integer;
begin // this default implementation will send all frames one by one
  n := FramesCount;
  if (n>0) and (Owner<>nil) then begin
    result := false;
    FramesCount := 0;
    for i := 0 to n-1 do
      if Owner.SendFrame(Frames[i]) then
        Frames[i].payload := '' else
        exit;
  end;
  result := true;
end;


{ TWebSocketFrameList }

function TWebSocketFrameList.Pop(protocol: TWebSocketProtocol; const head: RawUTF8;
  out frame: TWebSocketFrame): boolean;
var i: integer;
begin
  result := false;
  if (self=nil) or (Count=0) or (head='') or (protocol=nil) then
    exit;
  Acquire;
  try
    for i := 0 to Count-1 do
      if protocol.FrameIs(List[i],head) then begin
        result := true;
        frame := List[i];
        List[i].payload := '';
        dec(Count);
        if i<Count then
          Move(List[i+1],List[i],(Count-i)*sizeof(List[i]));
        exit;
      end;
  finally
    Release;
  end;
end;

procedure TWebSocketFrameList.Push(const frame: TWebSocketFrame);
begin
  if self=nil then
    exit;
  Acquire;
  try
    if Count>=length(List) then
      SetLength(List,Count+Count shr 3+8);
    List[Count] := frame;
    inc(Count);
  finally
    Release;
  end;
end;


{ TWebSocketProtocolChat }

function TWebSocketProtocolChat.Clone: TWebSocketProtocol;
begin
  result := TWebSocketProtocolChat.Create(fName,fURI);
  TWebSocketProtocolChat(result).OnIncomingFrame := OnIncomingFrame;
end;

procedure TWebSocketProtocolChat.ProcessIncomingFrame(Sender: TWebSocketProcess;
  var request: TWebSocketFrame);
begin
  if Assigned(OnInComingFrame) and
     Sender.InheritsFrom(TWebSocketProcessServer) then
    OnIncomingFrame(TWebSocketProcessServer(Sender).fServerResp,request);
end;

function TWebSocketProtocolChat.SendFrame(Sender: THttpServerResp;
  const frame: TWebSocketFrame): boolean;
begin
  result := false;
  if (self=nil) or (Sender=nil) or TThreadHook(Sender).Terminated or
     not (Frame.opcode in [focText,focBinary]) then
    exit;
  if (Sender.Server as TWebSocketServer).IsActiveWebSocket(Sender)=Sender then
    result := (Sender as TWebSocketServerResp).fProcess.SendFrame(frame)
end;


{ TWebSocketProtocolRest }

procedure TWebSocketProtocolRest.ProcessIncomingFrame(Sender: TWebSocketProcess;
  var request: TWebSocketFrame);
var Ctxt: THttpServerRequest;
    onRequest: TOnHttpServerRequest;
    status: cardinal;
    noAnswer: boolean;
    answer: TWebSocketFrame;
begin
  if not (request.opcode in [focText,focBinary]) then
    exit; // ignore e.g. from TWebSocketServerResp.ProcessStart/ProcessStop
  if FrameIs(request,'request') then begin
    Ctxt := Sender.ComputeContext(onRequest);
    try
      if not FrameToInput(request,noAnswer,Ctxt) then
        raise ESynBidirSocket.CreateUTF8('%.ProcessOne: invalid frame',[self]);
      request.payload := '';
      status := onRequest(Ctxt);
      if (Ctxt.OutContentType=HTTP_RESP_NORESPONSE) or noAnswer then
        exit;
      OutputToFrame(Ctxt,status,answer);
      Sender.SendFrame(answer);
    finally
      Ctxt.Free;
    end;
  end else
    Sender.fIncoming.Push(request); 
end;

const
  BOOL: array[boolean] of RawByteString = ('0','1');
  
procedure TWebSocketProtocolRest.InputToFrame(Ctxt: THttpServerRequest;
  aNoAnswer: boolean; out request: TWebSocketFrame);
begin
  FrameCompress(['request',Ctxt.Method,Ctxt.URL,Ctxt.InHeaders,BOOL[aNoAnswer]],
    Ctxt.InContent,Ctxt.InContentType,request);
end;

function TWebSocketProtocolRest.FrameToInput(var request: TWebSocketFrame;
  out aNoAnswer: boolean; Ctxt: THttpServerRequest): boolean;
var URL,Method,InHeaders,NoAnswer,InContentType,InContent: RawByteString;
begin
  result := FrameDecompress(request,'request',
    [@Method,@URL,@InHeaders,@NoAnswer],InContentType,InContent);
  if result then begin
    Ctxt.Prepare(URL,Method,InHeaders,InContent,InContentType);
    aNoAnswer := NoAnswer=BOOL[true];
  end;
end;

procedure TWebSocketProtocolRest.OutputToFrame(Ctxt: THttpServerRequest;
  Status: Cardinal; out answer: TWebSocketFrame);
begin
  FrameCompress(['answer',UInt32ToUTF8(Status),Ctxt.OutCustomHeaders],
    Ctxt.OutContent,Ctxt.OutContentType,answer);
end;

function TWebSocketProtocolRest.FrameToOutput(
  var answer: TWebSocketFrame; Ctxt: THttpServerRequest): cardinal;
var status,outHeaders,outContentType,outContent: RawByteString;
begin
  result := STATUS_NOTFOUND;
  if not FrameDecompress(answer,'ANSWER',
      [@status,@outHeaders],outContentType,outContent) then
    exit;
  result := GetInteger(pointer(status));
  Ctxt.OutCustomHeaders := outHeaders;
  Ctxt.OutContentType := outContentType;
  Ctxt.OutContent := outContent;
end;


{ TWebSocketProtocolJSON }

constructor TWebSocketProtocolJSON.Create(const aURI: RawUTF8);
begin
  inherited Create('synopsejson',aURI);
end;

function TWebSocketProtocolJSON.Clone: TWebSocketProtocol;
begin
  result := TWebSocketProtocolJSON.Create(fURI);
end;

procedure TWebSocketProtocolJSON.FrameCompress(const Values: array of RawByteString;
  const Content, ContentType: RawByteString; var frame: TWebSocketFrame);
var WR: TTextWriter;
    i: integer;
begin
  frame.opcode := focText;
  WR := TTextWriter.CreateOwnedStream;
  try
    WR.Add('{');
    WR.AddFieldName(Values[0]);
    WR.Add('[');
    for i := 1 to High(Values) do begin
      WR.Add('"');
      WR.AddJSONEscape(pointer(Values[i]));
      WR.Add('"',',');
    end;
    WR.Add('"');
    WR.AddString(ContentType);
    WR.Add('"',',');
    if Content='' then
      WR.Add('"','"') else
    if (ContentType='') or
       IdemPropNameU(ContentType,JSON_CONTENT_TYPE) then
      WR.AddNoJSONEscape(pointer(Content)) else
    if IdemPChar(pointer(ContentType),'TEXT/') then
      WR.AddCSVUTF8([Content]) else
      WR.WrBase64(pointer(Content),length(Content),true);
    WR.Add(']','}');
    WR.SetText(RawUTF8(frame.payload));
  finally
    WR.Free;
  end;
end;

function JsonFrameIs(const frame: TWebSocketFrame; const Head: RawUTF8): PUTF8Char;
var P,txt: PUTF8Char;
begin
  result := nil;
  if (length(frame.payload)<10) or (frame.opcode<>focText) then
    exit;
  P := pointer(frame.payload);
  P := GotoNextNotSpace(P);
  if P^<>'{' then
    exit;
  repeat
    inc(P);
    if P^=#0 then exit;
  until P^='"';
  txt := P+1;
  P := GotoEndOfJSONString(P);
  if (P^<>#0) and IdemPropNameU(Head,txt,P-txt) then
    result := P;
end;
 
function TWebSocketProtocolJSON.FrameIs(const frame: TWebSocketFrame;
  const Head: RawUTF8): boolean;
begin
  result := JsonFrameIs(frame,Head)<>nil;
end;

function TWebSocketProtocolJSON.FrameDecompress(
  const frame: TWebSocketFrame; const Head: RawUTF8;
  const values: array of PRawByteString; var contentType,
  content: RawByteString): Boolean;
var i: Integer;
    P,txt: PUTF8Char;
begin
  result := false;
  P := JsonFrameIs(frame,Head);
  if P=nil then
    exit;
  P := GotoNextNotSpace(P+1);
  if P^<>':' then
    exit;
  P := GotoNextNotSpace(P+1);
  if P^<>'[' then
    exit;
  inc(P);
  for i := 0 to high(values) do
    values[i]^ := GetJSONField(P,P);
  contentType := GetJSONField(P,P);
  if P=nil then
    exit;
  if (contentType='') or
     IdemPropNameU(contentType,JSON_CONTENT_TYPE) then
    content := GetJSONItemAsRawJSON(P) else begin
    txt := GetJSONField(P,P);
    if IdemPChar(pointer(contentType),'TEXT/') then
      SetString(content,txt,StrLen(txt)) else
    if not Base64MagicCheckAndDecode(txt,content) then
      exit;
  end;
  result := true;
end;

function TWebSocketProtocolJSON.FrameType(
  const frame: TWebSocketFrame): RawUTF8;
var P,txt: PUTF8Char;
begin
  result := '';
  if (length(frame.payload)<10) or (frame.opcode<>focText) then
    exit;
  P := pointer(frame.payload);
  if not IdemPChar(P,'{"') then
    exit;
  inc(P,2);
  txt := P;
  P := GotoEndOfJSONString(P);
  SetString(result,txt,P-Txt);
end;


{ TWebSocketProtocolBinary }

constructor TWebSocketProtocolBinary.Create(const aURI: RawUTF8;
  const aKey; aKeySize: cardinal; aCompressed: boolean);
begin
  inherited Create('synopsebinary',aURI);
  if aKeySize>=128 then
    fEncryption := TAESCFB.Create(aKey,aKeySize);
  fCompressed := aCompressed;
end;

constructor TWebSocketProtocolBinary.Create(const aURI, aKey: RawUTF8;
  aCompressed: boolean);
var key: TSHA256Digest;
    keySize: integer;
begin
  if aKey<>'' then begin
    SHA256Weak(aKey,key);
    keySize := 256;
  end else
    keySize := 0;
  Create(aURI,key,keySize,aCompressed);
end;

function TWebSocketProtocolBinary.Clone: TWebSocketProtocol;
begin
  result := TWebSocketProtocolBinary.Create(fURI,self,0,fCompressed);
  if fEncryption<>nil then
    TWebSocketProtocolBinary(result).fEncryption := fEncryption.Clone;
end;

destructor TWebSocketProtocolBinary.Destroy;
begin
  FreeAndNil(fEncryption);
  inherited;
end;

procedure TWebSocketProtocolBinary.FrameCompress(const Values: array of RawByteString;
  const Content, ContentType: RawByteString; var frame: TWebSocketFrame);
var tmp,value: RawByteString;
    i: integer;
begin
  frame.opcode := focBinary;
  for i := 1 to high(Values) do
    tmp := tmp+Values[i]+#1;
  tmp := tmp+ContentType+#1+Content;
  if fCompressed then
    SynLZCompress(pointer(tmp),length(tmp),value,512) else
    value := tmp;
  if fEncryption<>nil then
    value := fEncryption.EncryptPKCS7(value,true);
  frame.payload := Values[0]+#1+value;
end;

function TWebSocketProtocolBinary.FrameIs(const frame: TWebSocketFrame;
  const Head: RawUTF8): boolean;
var headLen: integer;
begin
  headLen := length(Head);
  result := (frame.opcode=focBinary) and
            (length(frame.payload)>=headLen+6) and
            (frame.payload[headLen+1]=#1) and
            IdemPropNameU(Head,pointer(frame.payload),headLen);
end;

function TWebSocketProtocolBinary.FrameType(
  const frame: TWebSocketFrame): RawUTF8;
var i: integer;
begin
  if (length(frame.payload)<10) or (frame.opcode<>focBinary) then
    i := 0 else
    i := PosEx(#1,frame.payload);
  if i=0 then
    result := '' else
    result := copy(frame.payload,1,i-1);
end;

function TWebSocketProtocolBinary.FrameDecompress(
  const frame: TWebSocketFrame; const Head: RawUTF8;
  const values: array of PRawByteString; var contentType,content: RawByteString): Boolean;
var tmp,value: RawByteString;
    i: integer;
    P: PUTF8Char;
begin
  result := false;
  if not FrameIs(frame,Head) then
    exit;
  tmp := copy(frame.payload,length(Head)+2,maxInt);
  if fEncryption<>nil then
    tmp := fEncryption.DecryptPKCS7(tmp,true);
  if fCompressed then
    SynLZDecompress(pointer(tmp),length(tmp),value) else
    value := tmp;
  if length(value)<4 then
    exit;
  P := pointer(value);
  for i := 0 to high(values) do
    values[i]^ := GetNextItem(P,#1);
  contentType := GetNextItem(P,#1);
  if P<>nil then
    SetString(content,P,length(value)-(P-pointer(value)));
  result := true;
end;

function TWebSocketProtocolBinary.SendFrames(Owner: TWebSocketProcess;
  var Frames: TWebSocketFrameDynArray; var FramesCount: integer): boolean;
var jumboFrame: TWebSocketFrame;
    fr: TDynArray;
begin
  if (FramesCount=0) or (Owner=nil) then begin
    result := true;
    exit;
  end;
  if FramesCount=1 then begin
    FramesCount := 0;
    result := Owner.SendFrame(Frames[0]);
    exit;
  end;
  fr.Init(TypeInfo(TWebSocketFrameDynArray),Frames);
  fr.UseExternalCount(FramesCount);
  jumboFrame.opcode := focBinary;
  jumboFrame.payload := 'frames'#1+fr.SaveTo; // each frame is already encrypted
  FramesCount := 0;
  Frames := nil;
  result := Owner.SendFrame(jumboFrame); // send all frames at once
end;

procedure TWebSocketProtocolBinary.ProcessIncomingFrame(Sender: TWebSocketProcess;
  var request: TWebSocketFrame);
var jumbo: RawByteString;
    i: integer;
    frames: TWebSocketFrameDynArray;
begin
  if FrameIs(request,'frames') then begin
    jumbo := copy(request.payload,8,maxInt);
    if DynArrayLoad(frames,pointer(jumbo),TypeInfo(TWebSocketFrameDynArray))=nil then
      raise ESynBidirSocket.CreateUTF8(
        'Invalid content for %.ProcessIncomingFrame(frames)',[self]);
    for i := 0 to high(frames) do begin
      Sender.Log(frames[i],'GetSubFrame');
      ProcessIncomingFrame(Sender,frames[i]);
    end;
  end else
    inherited ProcessIncomingFrame(Sender,request);
end;


{ TWebSocketProtocolList }

function TWebSocketProtocolList.CloneByName(const aProtocolName, aURI: RawUTF8): TWebSocketProtocol;
var i: Integer;
begin
  i := FindIndex(aProtocolName,aURI);
  if i<0 then
    result := nil else
    result := fProtocols[i].Clone;
end;

function TWebSocketProtocolList.CloneByURI(
  const aURI: RawUTF8): TWebSocketProtocol;
var i: integer;
begin
  result := nil;
  if self<>nil then
    for i := 0 to length(fProtocols)-1 do
      if IdemPropNameU(fProtocols[i].fURI,aURI) then begin
        result := fProtocols[i].Clone;
        exit;
      end;
end;

function TWebSocketProtocolList.Count: integer;
begin
  if self=nil then
    result := 0 else
    result := length(fProtocols);
end;

destructor TWebSocketProtocolList.Destroy;
begin
  ObjArrayClear(fProtocols);
  inherited;
end;

function TWebSocketProtocolList.FindIndex(const aName,aURI: RawUTF8): integer;
begin
  if aName<>'' then
    for result := 0 to high(fProtocols) do
      with fProtocols[result] do
      if IdemPropNameU(fName,aName) and
         ((fURI='') or IdemPropNameU(fURI,aURI)) then
        exit;
  result := -1;
end;

function TWebSocketProtocolList.Add(aProtocol: TWebSocketProtocol): boolean;
var i: Integer;
begin
  result := false;
  if aProtocol=nil then
    exit;
  i := FindIndex(aProtocol.Name,aProtocol.URI);
  if i<0 then begin
    ObjArrayAdd(fProtocols,aProtocol);
    result := true;
  end;
end;

function TWebSocketProtocolList.AddOnce(
  aProtocol: TWebSocketProtocol): boolean;
var i: Integer;
begin
  result := false;
  if aProtocol=nil then
    exit;
  i := FindIndex(aProtocol.Name,aProtocol.URI);
  if i<0 then begin
    ObjArrayAdd(fProtocols,aProtocol);
    result := true;
  end else begin
    fProtocols[i].Free;
    fProtocols[i] := aProtocol;
  end;
end;

function TWebSocketProtocolList.Remove(const aProtocolName,aURI: RawUTF8): Boolean;
var i: Integer;
begin
  i := FindIndex(aProtocolName,aURI);
  if i>=0 then begin
    ObjArrayDelete(fProtocols,i);
    result := true;
  end else
    result := false;
end;


{ TWebSocketProcess }

constructor TWebSocketProcess.Create(aSocket: TCrtSocket;
  aProtocol: TWebSocketProtocol; aOwner: TNotifiedThread;
  const aSettings: TWebSocketProcessSettings);
begin
  inherited Create;
  fSocket := aSocket;
  fProtocol := aProtocol;
  fOwnerThread := aOwner;
  fSettings := aSettings;
  fIncoming := TWebSocketFrameList.Create;
  fOutgoing := TWebSocketFrameList.Create;
end;

destructor TWebSocketProcess.Destroy;
var frame: TWebSocketFrame;
begin
  WebSocketLog.Enter(self);
  if fState<>wpsClose then begin 
    fState := wpsDestroy;
    if fOutgoing.Count>0 then
      SendPendingOutgoingFrames;
    frame.opcode := focConnectionClose;
    if SendFrame(frame) then // notify clean closure
      GetFrame(frame,1000);  // expects an answer from the other side
  end else
    fState := wpsDestroy;
  while fProcessCount>0 do
    SleepHiRes(2);
  fProtocol.Free;
  fOutgoing.Free;
  fIncoming.Free;
  inherited Destroy;
end;

const
  FRAME_FIN=128;
  FRAME_LEN2BYTES=126;
  FRAME_LEN8BYTES=127;

type
 TFrameHeader = packed record
   first: byte;
   len8: byte;
   len32: cardinal;
   len64: cardinal;
   mask: cardinal; // 0 indicates no payload masking
 end;

procedure ProcessMask(data: pointer; mask: cardinal; len: integer);
var i,maskCount: integer;
begin
  maskCount := len shr 2;
  for i := 0 to maskCount-1 do
    PCardinalArray(data)^[i] := PCardinalArray(data)^[i] xor mask;
  maskCount := maskCount*4;
  for i := maskCount to maskCount+(len and 3)-1 do begin
    PByteArray(data)^[i] := PByteArray(data)^[i] xor mask;
    mask := mask shr 8;
  end;
end;

function TWebSocketProcess.GetFrame(out Frame: TWebSocketFrame;
  TimeOut: cardinal): boolean;
var hdr: TFrameHeader;
    opcode: TWebSocketFrameOpCode;
    masked: boolean;
procedure GetHeader;
begin
  fillchar(hdr,sizeof(hdr),0);
  fSocket.SockInRead(@hdr.first,2,true);
  opcode := TWebSocketFrameOpCode(hdr.first and 15);
  masked := hdr.len8 and 128<>0;
  if masked then
    hdr.len8 := hdr.len8 and 127;
  if hdr.len8<FRAME_LEN2BYTES then
    hdr.len32 := hdr.len8 else
  if hdr.len8=FRAME_LEN2BYTES then begin
    fSocket.SockInRead(@hdr.len32,2,true);
    hdr.len32 := swap(hdr.len32);
  end else
  if hdr.len8=FRAME_LEN8BYTES then begin
    fSocket.SockInRead(@hdr.len32,8,true);
    if hdr.len32<>0 then // size is more than 32 bits -> reject
      hdr.len32 := maxInt else
      hdr.len32 := bswap32(hdr.len64);
    if hdr.len32>1 shl 28 then
      raise ESynBidirSocket.CreateUTF8('%.GetFrame: length should be < 256MB',[self]);
  end;
  if masked then
    fSocket.SockInRead(@hdr.mask,4,true);
end;
procedure GetData(var data: RawByteString);
begin
  SetString(data,nil,hdr.len32);
  fSocket.SockInRead(pointer(data),hdr.len32);
  if hdr.mask<>0 then
    ProcessMask(pointer(data),hdr.mask,hdr.len32);
end;
var data: RawByteString;
begin
  result := false;
  try
    if fSocket.SockInPending(TimeOut)<2 then
      exit; // no data available
    GetHeader;
    Frame.opcode := opcode;
    GetData(Frame.payload);
    while hdr.first and FRAME_FIN=0 do begin // handle partial payloads
      GetHeader;
      if (opcode<>focContinuation) and (opcode<>Frame.opcode) then
        raise ESynBidirSocket.CreateUTF8('%.GetFrame: received %, expected %',
          [self,OpcodeText(opcode)^,OpcodeText(Frame.opcode)^]);
      GetData(data);
      Frame.payload := Frame.payload+data;
    end;
    {$ifdef UNICODE}
    if opcode=focText then
      SetCodePage(Frame.payload,CP_UTF8,false); // identify text value as UTF-8
    {$endif}
    Log(frame,'GetFrame');
    SetLastPingTicks;
    result := true;
  except
    result := false;
  end;
end;

procedure TWebSocketProcess.ProcessStart;
begin
  SetLastPingTicks;
end;

procedure TWebSocketProcess.ProcessStop;
begin // nothing to do at this level
end;

function TWebSocketProcess.SendFrame(
  const Frame: TWebSocketFrame): boolean;
var hdr: TFrameHeader;
    len: cardinal;
begin
  Log(frame,'SendFrame');
  try
    result := true;
    len := Length(Frame.payload);
    hdr.first := byte(Frame.opcode) or FRAME_FIN;
    if fMaskSentFrames<>0 then begin
      hdr.mask := (GetTickCount64 xor PtrInt(self))*Random(MaxInt);
      ProcessMask(pointer(Frame.payload),hdr.mask,len);
    end;
    if len<FRAME_LEN2BYTES then begin
      hdr.len8 := len or fMaskSentFrames;
      fSocket.Snd(@hdr,2);
    end else
    if len<65536 then begin
      hdr.len8 := FRAME_LEN2BYTES or fMaskSentFrames;
      hdr.len32 := swap(len);
      fSocket.Snd(@hdr,4);
    end else begin
      hdr.len8 := FRAME_LEN8BYTES or fMaskSentFrames;
      hdr.len64 := bswap32(len);
      hdr.len32 := 0;
      fSocket.SndLow(@hdr,10+fMaskSentFrames shr 5);
      // huge payload sent outside TCrtSock buffers
      fSocket.SndLow(pointer(Frame.payload),len);
      SetLastPingTicks;
      exit;
    end;
    if fMaskSentFrames<>0 then
      fSocket.Snd(@hdr.mask,4);
    fSocket.Snd(pointer(Frame.payload),len);
    fSocket.SockSendFlush; // send at once up to 64 KB
    SetLastPingTicks;
  except
    result := false;
  end;
end;

function TWebSocketProcess.HiResDelay(timeout: cardinal): boolean;
var elapsed,delay: cardinal;
begin
  elapsed := LastPingDelay;
  if (timeout<>0) and (elapsed>timeout) then
    result := true else begin
    case elapsed of
    0..50:      delay := 0;
    51..200:    delay := 1;
    201..500:   delay := 5;
    501..2000:  delay := 50;
    2001..5000: delay := 100;
    else        delay := 500;
    end;
    if (fSettings.LoopDelay<>0) and (delay>fSettings.LoopDelay) then
      delay := fSettings.LoopDelay;
    if (timeout<>0) and (elapsed+delay>timeout) then
      delay := timeout-elapsed;
    SleepHiRes(delay);
    result := (timeout<>0) and (LastPingDelay>=timeout);
  end;
end;

function TWebSocketProcess.NotifyCallback(
  aRequest: THttpServerRequest; aMode: TWebSocketProcessNotifyCallback): cardinal;
var request,answer: TWebSocketFrame;
begin
  WebSocketLog.Add.Log(sllDebug,'%.NotifyCallback(%,%)',[ClassType,aRequest.URL,
     GetEnumName(TypeInfo(TWebSocketProcessNotifyCallback),ord(aMode))^]); 
  result := STATUS_NOTFOUND;
  if (fProtocol=nil) or
     not fProtocol.InheritsFrom(TWebSocketProtocolRest) then
    exit;
  TWebSocketProtocolRest(fProtocol).InputToFrame(
    aRequest,aMode in [wscBlockWithoutAnswer,wscNonBlockWithoutAnswer],request);
  if aMode=wscNonBlockWithoutAnswer then begin
    // add to the internal sending list for asynchronous sending
    fOutgoing.Push(request);
    Log(request,'NotifyCallback');
    result := STATUS_SUCCESS;
    exit;
  end;
  InterlockedIncrement(fProcessCount);
  try
    // now we should be alone on the wire -> send REST request
    if not SendFrame(request) then
      exit;
    if aMode=wscBlockWithoutAnswer then begin
      result := STATUS_SUCCESS;
      exit;
    end;
    while not fIncoming.Pop(fProtocol,'answer',answer) do
      if fState in [wpsDestroy,wpsClose] then begin
        result := STATUS_WEBSOCKETCLOSED;
        exit;
      end else
      if HiResDelay(fSettings.CallbackAnswerTimeOutMS) then begin
        Log(request,'NotifyCallback TIMEOUT',sllWarning);
        exit;
      end;
  finally
    InterlockedDecrement(fProcessCount);
  end;
  result := TWebSocketProtocolRest(fProtocol).FrameToOutput(answer,aRequest);
end;

procedure TWebSocketProcess.SendPendingOutgoingFrames;
begin
  fOutgoing.Acquire;
  try
    if not fProtocol.SendFrames(self,fOutgoing.List,fOutgoing.Count) then
      WebSocketLog.Add.Log(sllError,'%.ProcessLoop SendFrames',[self]);
  finally
    fOutgoing.Release;
  end;
end;

function TWebSocketProcess.ProcessLoop: boolean;
var request: TWebSocketFrame;
    elapsed: cardinal;
begin
  result := false;
  if fProtocol=nil then
    exit;
  ProcessStart;
  fState := wpsRun;
  while (fState<>wpsDestroy) and
        (not TThreadHook(fOwnerThread).Terminated) do
    try
      InterlockedIncrement(fProcessCount);
      try
        if GetFrame(request,1) then begin
          case request.opcode of
          focPing: begin
            request.opcode := focPong;
            SendFrame(request);
          end;
          focPong:
            continue;
          focText,focBinary:
            fProtocol.ProcessIncomingFrame(self,request);
          focConnectionClose: begin
            SendFrame(request);
            fState := wpsClose;
            result := true; // indicates gracefully closed by server
            break; // will close the connection 
          end;
          end;
        end else
        if TThreadHook(fOwnerThread).Terminated then
           break else begin
          elapsed := LastPingDelay;
          if (elapsed>0) and (fOutgoing.Count>0) then
            SendPendingOutgoingFrames else
          if (fSettings.HeartbeatDelay<>0) and
             (elapsed>fSettings.HeartbeatDelay) then begin
            request.opcode := focPing;
            if SendFrame(request) then
              fInvalidPingSendCount := 0 else
              if (fSettings.DisconnectAfterInvalidHeartbeatCount<>0) and
                 (fInvalidPingSendCount>
                  fSettings.DisconnectAfterInvalidHeartbeatCount) then begin
                fState := wpsCLose;
                result := true;
                break; // will close the connection
              end else begin
                inc(fInvalidPingSendCount);
                SetLastPingTicks; // avoid endless retry in case of broken socket
              end;
          end;
        end;
      finally
        request.payload := '';
        InterlockedDecrement(fProcessCount);
      end;
      HiResDelay(0);
    except
      HiResDelay(50);
    end;
  ProcessStop;
end;


{ -------------- WebSockets Server classes for bidirectional remote access }

procedure ComputeChallenge(const Base64: RawByteString; out Digest: TSHA1Digest);
const SALT: string[36] = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
var SHA: TSHA1;
begin
  SHA.Init;
  SHA.Update(pointer(Base64),length(Base64));
  SHA.Update(@salt[1],36);
  SHA.Final(Digest);
end;

procedure TWebSocketProcess.SetLastPingTicks;
begin
  Acquire;
  fLastSocketTicks := GetTickCount64;
  Release;
end;

function TWebSocketProcess.LastPingDelay: Int64;
begin
  Acquire;
  result := GetTickCount64-fLastSocketTicks;
  Release;
end;

procedure TWebSocketProcess.Log(const frame: TWebSocketFrame;
  const aMethodName: RawUTF8; aEvent: TSynLogInfo);
begin
  if WebSocketLog<>nil then
  with WebSocketLog.Family do
  if aEvent in Level then
    SynLog.Log(aEvent,'%.%(%) % len=%',[Self.ClassType,aMethodName,
      Protocol.FrameType(frame),OpcodeText(frame.opcode)^,length(frame.PayLoad)]);
end;


{ TWebSocketServer }

constructor TWebSocketServer.Create(const aPort: SockString);
begin
  inherited Create(aPort{$ifdef USETHREADPOOL},0{$endif}); // no thread pool
  fThreadRespClass := TWebSocketServerResp;
  fConnections := TObjectList.Create(false);
  fProtocols := TWebSocketProtocolList.Create;
  fSettings.SetDefaults;
  fSettings.HeartbeatDelay := 20000;
end;

function TWebSocketServer.WebSocketProcessUpgrade(ClientSock: THttpServerSocket;
  Context: TWebSocketServerResp): boolean;
var upgrade,uri,version,protocol,key: RawUTF8;
    P: PUTF8Char;
    Digest: TSHA1Digest;
    prot: TWebSocketProtocol;
    i: integer;
begin
  result := false; // quiting now will process it like a regular GET HTTP request
  if Context.fProcess<>nil then
    exit; // already upgraded
  upgrade := ClientSock.HeaderValue('Upgrade');
  if not IdemPropNameU(upgrade,'websocket') then
    exit;
  version := ClientSock.HeaderValue('Sec-WebSocket-Version');
  if GetInteger(pointer(version))<13 then
    exit; // we expect WebSockets protocol version 13 at least
  uri := Trim(RawUTF8(ClientSock.URL));
  if (uri<>'') and (uri[1]='/') then
    Delete(uri,1,1);
  protocol := ClientSock.HeaderValue('Sec-WebSocket-Protocol');
  P := pointer(protocol);
  if P<>nil then
    repeat
      prot := fProtocols.CloneByName(trim(GetNextItem(P)),uri);
    until (P=nil) or (prot<>nil) else
    // if no protocol is specified, try to match by URI
    prot := fProtocols.CloneByURI(uri);
  if prot=nil then
    exit;
  Context.fProcess := TWebSocketProcessServer.Create(
    ClientSock,prot,Context,fSettings);
  Context.fProcess.fServerResp := Context;
  key := ClientSock.HeaderValue('Sec-WebSocket-Key');
  if Base64ToBinLength(pointer(key),length(key))<>16 then
    exit; // this nonce must be a Base64-encoded value of 16 bytes
  ComputeChallenge(key,Digest);
  ClientSock.SockSend(['HTTP/1.1 101 Switching Protocols'#13#10+
    'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10+
    'Sec-WebSocket-Protocol: ',prot.Name,#13#10+
    'Sec-WebSocket-Accept: ',BinToBase64(@Digest,sizeof(Digest)),#13#10]);
  ClientSock.SockSendFlush;
  EnterCriticalSection(fProcessCS);
  fConnections.Add(Context);
  LeaveCriticalSection(fProcessCS);
  try
    result := Context.fProcess.ProcessLoop;
    ClientSock.KeepAliveClient := false; // always close connection
  finally
    FreeAndNil(Context.fProcess); // notify end of WebSockets
    EnterCriticalSection(fProcessCS);
    i := fConnections.IndexOf(Context);
    if i>=0 then
      fConnections.Delete(i);
    LeaveCriticalSection(fProcessCS);
  end;
end;

procedure TWebSocketServer.Process(ClientSock: THttpServerSocket;
  aCallingThread: TNotifiedThread);
begin
  if ClientSock.ConnectionUpgrade and
     ClientSock.KeepAliveClient and
     IdemPropName(ClientSock.Method,'GET') and
     aCallingThread.InheritsFrom(TWebSocketServerResp) then
    WebSocketProcessUpgrade(ClientSock,TWebSocketServerResp(aCallingThread)) else
    inherited Process(ClientSock,aCallingThread);
end;

destructor TWebSocketServer.Destroy;
begin
  inherited Destroy; // close any pending connection
  fConnections.Free;
  fProtocols.Free;
end;

function TWebSocketServer.IsActiveWebSocket(
  CallingThread: TNotifiedThread): TWebSocketServerResp;
var connectionIndex: Integer;
begin
  result := nil;
  if Terminated or (CallingThread=nil) then
    exit;
  EnterCriticalSection(fProcessCS);
  connectionIndex := fConnections.IndexOf(CallingThread);
  LeaveCriticalSection(fProcessCS);
  if (connectionIndex>=0) and
     CallingThread.InheritsFrom(TWebSocketServerResp) then
    //  this request is a websocket, on a non broken connection
    result := TWebSocketServerResp(CallingThread);
end;


{ TWebSocketServerRest }

constructor TWebSocketServerRest.Create(const aPort: SockString;
  const aWebSocketsURI,aWebSocketsEncryptionKey: RawUTF8; aWebSocketsAJAX: boolean);
begin
  Create(aPort);
  WebSocketsEnable(aWebSocketsURI,aWebSocketsEncryptionKey,aWebSocketsAJAX);
end;

procedure TWebSocketServerRest.WebSocketsEnable(const aWebSocketsURI,
  aWebSocketsEncryptionKey: RawUTF8; aWebSocketsAJAX,aWebSocketsCompressed: boolean);
begin
  if self=nil  then
    exit;
  fProtocols.AddOnce(TWebSocketProtocolBinary.Create(
    aWebSocketsURI,aWebSocketsEncryptionKey,aWebSocketsCompressed));
  if aWebSocketsAJAX then
    fProtocols.AddOnce(TWebSocketProtocolJSON.Create(aWebSocketsURI));
end;

constructor TWebSocketServerRest.Create(const aPort: SockString);
begin
  inherited Create(aPort);
  fCallbackAcquireTimeOutMS := 5000;
  fCallbackAnswerTimeOutMS := 30000;
end;

function TWebSocketServerRest.WebSocketsCallback(
  Ctxt: THttpServerRequest; aMode: TWebSocketProcessNotifyCallback): cardinal;
var connection: TWebSocketServerResp;
begin
  WebSocketLog.Add.Log(sllTrace,'%.WebSocketsCallback % on %',
    [ClassType,Ctxt.URL,Ctxt.CallingThread]); 
  if Ctxt=nil then
    connection := nil else
    connection := IsActiveWebSocket(Ctxt.CallingThread);
  if connection<>nil then
    //  this request is a websocket, on a non broken connection
    result := connection.NotifyCallback(Ctxt,aMode) else begin
    WebSocketLog.Add.Log(sllError,'%.WebSocketsCallback on inactive socket %',
      [ClassType,Ctxt.CallingThread]);
    result := STATUS_NOTFOUND;
  end;
end;


{ TWebSocketServerResp }

constructor TWebSocketServerResp.Create(aServerSock: THttpServerSocket;
  aServer: THttpServer {$ifdef USETHREADPOOL}; aThreadPool: TSynThreadPoolTHttpServer{$endif});
begin
  if not aServer.InheritsFrom(TWebSocketServer) then
    raise ESynBidirSocket.CreateUTF8('%.Create(%: TWebSocketServer?)',[self,aServer]);
  inherited Create(aServerSock,aServer{$ifdef USETHREADPOOL},aThreadPool{$endif});
  if aServer.InheritsFrom(TWebSocketServerRest) then
    fSettings := TWebSocketServerRest(aServer).fSettings else
    fSettings.SetDefaults;
end;

function TWebSocketServerResp.NotifyCallback(Ctxt: THttpServerRequest;
  aMode: TWebSocketProcessNotifyCallback): cardinal;
begin
  if fProcess=nil then
    result := STATUS_NOTFOUND else begin
    result := fProcess.NotifyCallback(Ctxt,aMode);
    if result=STATUS_WEBSOCKETCLOSED then begin
      WebSocketLog.Add.Log(sllError,'%.NotifyCallback on closed connection',[self]);
      ServerSock.KeepAliveClient := false; // force close the connection
      result := STATUS_NOTFOUND;
    end;
  end;
end;

function TWebSocketServerResp.WebSocketProtocol: TWebSocketProtocol;
begin
  if (Self=nil) or (fProcess=nil) then
    result := nil else
    result := fProcess.Protocol;
end;


{ TWebSocketProcessServer }

function TWebSocketProcessServer.ComputeContext(
  out RequestProcess: TOnHttpServerRequest): THttpServerRequest;
begin
  result := THttpServerRequest.Create(
    (fOwnerThread as TWebSocketServerResp).fServer,fOwnerThread);
  RequestProcess := TWebSocketServerResp(fOwnerThread).fServer.Request;
end;


procedure TWebSocketProcessServer.ProcessStart;
var frame: TWebSocketFrame;
begin // notify e.g. TOnWebSocketProtocolChatIncomingFrame
  inherited;
  frame.opcode := focContinuation;
  fProtocol.ProcessIncomingFrame(self,frame);
end;

procedure TWebSocketProcessServer.ProcessStop;
var frame: TWebSocketFrame;
begin // notify e.g. TOnWebSocketProtocolChatIncomingFrame
  frame.opcode := focConnectionClose;
  fProtocol.ProcessIncomingFrame(self,frame);
  inherited;
end;


{ -------------- WebSockets Client classes for bidirectional remote access }

{ THttpClientWebSockets }

constructor THttpClientWebSockets.Create(aTimeOut: cardinal);
begin
  inherited;
  fSettings.SetDefaults;
  fSettings.CallbackAnswerTimeOutMS := aTimeOut;
end;

destructor THttpClientWebSockets.Destroy;
begin
  FreeAndNil(fProcess);
  inherited;
end;

function THttpClientWebSockets.Request(const url, method: SockString;
  KeepAlive: cardinal; const header, Data, DataType: SockString;
  retry: boolean): integer;
var Ctxt: THttpServerRequest;
begin
  if fProcess<>nil then
    if fProcess.fClientThread.fThreadState>sRun then
      // WebSockets closed by server side
      result := STATUS_NOTIMPLEMENTED else begin
      Ctxt := THttpServerRequest.Create(nil,fProcess.fOwnerThread);
      try
        Ctxt.Prepare(url,method,header,data,dataType);
        result := fProcess.NotifyCallback(Ctxt,wscBlockWithAnswer);
        HeaderSetText(Ctxt.OutCustomHeaders);
        Content := Ctxt.OutContent;
        ContentType := Ctxt.OutContentType;
        ContentLength := length(Ctxt.OutContent);
      finally
        Ctxt.Free;
      end;
    end else
    // standard HTTP/1.1 REST request
    result := inherited Request(url,method,KeepAlive,header,Data,DataType,retry);
end;

function THttpClientWebSockets.WebSocketsUpgrade(const aWebSocketsURI,
  aWebSocketsEncryptionKey: RawUTF8; aWebSocketsAJAX,aWebSocketsCompression: boolean): RawUTF8;
var protocol: TWebSocketProtocolRest;
    key: TAESBlock;
    bin1,bin2: RawByteString;
    cmd: SockString;
    digest1,digest2: TSHA1Digest;
begin
  if fProcess<>nil then begin
    result := 'Already upgraded to WebSockets';
    if IdemPropNameU(fProcess.Protocol.URI,aWebSocketsURI) then
      result := result+' on this URI' else
      result := FormatUTF8('% with URI="%" but requested "%"',
        [result,fProcess.Protocol.URI,aWebSocketsURI]);
    exit;
  end;
  try
    if aWebSocketsAJAX then
      protocol := TWebSocketProtocolJSON.Create(aWebSocketsURI) else
      protocol := TWebSocketProtocolBinary.Create(
        aWebSocketsURI,aWebSocketsEncryptionKey,aWebSocketsCompression);
    try
      RequestSendHeader(aWebSocketsURI,'GET');
      FillRandom(key);
      bin1 := BinToBase64(@key,sizeof(key));
      SockSend(['Content-Length: 0'#13#10'Connection: Upgrade'#13#10+
        'Upgrade: websocket'#13#10'Sec-WebSocket-Key: ',bin1,#13#10+
        'Sec-WebSocket-Protocol: ',protocol.Name,#13#10+
        'Sec-WebSocket-Version: 13'#13#10]);
      SockSendFlush;
      SockRecvLn(cmd);
      GetHeader;
      result := 'Invalid HTTP Upgrade Header';
      if not IdemPChar(pointer(cmd),'HTTP/1.1 101') or
         not ConnectionUpgrade or (ContentLength>0) or
         not IdemPropNameU(HeaderValue('upgrade'),'websocket') or
         not IdemPropNameU(HeaderValue('Sec-WebSocket-Protocol'),protocol.Name) then
        exit;
      result := 'Invalid HTTP Upgrade Accept Challenge';
      ComputeChallenge(bin1,digest1);
      bin2 := HeaderValue('Sec-WebSocket-Accept');
      if (Base64ToBinLength(pointer(bin2),length(bin2))<>sizeof(digest2)) then
        exit;
      SynCommons.Base64Decode(pointer(bin2),@digest2,length(bin2) shr 2);
      if not CompareMem(@digest1,@digest2,SizeOf(digest1)) then
        exit;
      // if we reached here, connection is successfully upgraded to WebSockets
      result := ''; // no error message = success
      fProcess := TWebSocketProcessClient.Create(self,protocol);
      protocol := nil; // protocol will be owned by fProcess now
    finally
      protocol.Free;
    end;
  except
    on E: Exception do begin
      FreeAndNil(fProcess);
      result := FormatUTF8('%: %',[E,E.Message]);
    end;
  end;
end;


{ TWebSocketProcessClient }

constructor TWebSocketProcessClient.Create(aSender: THttpClientWebSockets;
  aProtocol: TWebSocketProtocol);
begin
  fClientThread := TWebSocketProcessClientThread.Create(self);
  fMaskSentFrames := 128;
  inherited Create(aSender,aProtocol,fClientThread,aSender.fSettings);
end;

destructor TWebSocketProcessClient.Destroy;
begin
  while fClientThread.fThreadState=sCreate do
    SleepHiRes(1);
  if fClientThread.fThreadState<>sClosed then
  try
    InterlockedIncrement(fProcessCount);
    if fOutgoing.Count>0 then
      SendPendingOutgoingFrames;
    fClientThread.Terminate;
  finally
    InterlockedDecrement(fProcessCount);
  end;
  fClientThread.Free;
  inherited Destroy;
end;

function TWebSocketProcessClient.ComputeContext(
  out RequestProcess: TOnHttpServerRequest): THttpServerRequest;
begin
  result := THttpServerRequest.Create(nil,fOwnerThread);
  RequestProcess := (fSocket as THttpClientWebSockets).fRequestProcess;
end;


{ TWebSocketProcessClientThread }

constructor TWebSocketProcessClientThread.Create(
  aProcess: TWebSocketProcessClient);
begin
  fProcess := aProcess;
  inherited Create(false);
end;

procedure TWebSocketProcessClientThread.Execute;
begin
  fThreadState := sRun;
  if fProcess.ProcessLoop then
    fThreadState := sClosed else
    fThreadState := sFinished;
end;




end.
