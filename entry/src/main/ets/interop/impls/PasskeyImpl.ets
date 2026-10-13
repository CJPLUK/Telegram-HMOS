// Passkey capability — real @kit.OnlineAuthenticationKit (fido2) impl, Phase 3 reversal (SSOT §5).
// ArkTS owns the WebAuthn registration ceremony (fido2.register); cangjie PasskeysPage calls via
// callArkAsync and finishes the server side with account.registerPasskey (RealAuthService).
//
// iOS counterpart: PasskeysScreen.swift createPasskey() — ASAuthorizationPlatformPublicKeyCredentialProvider
// .createCredentialRegistrationRequest(challenge:name:userID:) driven by the server's
// PublicKeyCredentialCreationOptions JSON (account.initPasskeyRegistration).
//
// Methods:
//   PASSKEY_REGISTER = "passkey.register"
//     argJson (cangjie → ArkTS): {"optionsB64": string}
//         optionsB64 = standard base64 of the server options JSON ({"publicKey": {...}}).
//         Base64 on both legs keeps the payloads free of quotes/backslashes for the simplified
//         cangjie JsonParser (services/JsonParser.cj).
//     result (ArkTS → cangjie):
//         {"ok": true, "id": string, "rawId": string, "clientDataB64": string, "attestationB64": string}
//             id/rawId = base64url (no padding) of the credential id, same as iOS encodeBase64URL(credentialID);
//             clientDataB64 = base64 of the raw clientDataJSON bytes; attestationB64 = base64 of attestationObject.
//         {"ok": false, "code": number, "cancelled": boolean, "msg": string}
//             cancelled=true for user abort / reject (iOS didCompleteWithError is a no-op for those).
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import { fido2 } from '@kit.OnlineAuthenticationKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const ERR_NOT_SUPPORTED: number = 1021300001;
const ERR_USER_ABORT: number = 1021300004;
const ERR_USER_REJECT: number = 1021300010;
const ERR_DEVICE_TYPE: number = 801;
const ERR_CREDENTIAL_LIMIT: number = 1021300012;

interface PasskeyRegisterArgs {
  optionsB64: string;
}

// Shape of the server-issued WebAuthn PublicKeyCredentialCreationOptions JSON
// (account.initPasskeyRegistration → DataJSON). Only the fields fido2.register needs.
interface OptRp {
  id?: string;
  name?: string;
}

interface OptUser {
  id?: string;
  name?: string;
  displayName?: string;
}

interface OptParam {
  type?: string;
  alg?: number;
}

interface OptDescriptor {
  type?: string;
  id?: string;
}

interface OptSelection {
  authenticatorAttachment?: string;
  residentKey?: string;
  requireResidentKey?: boolean;
  userVerification?: string;
}

interface OptPublicKey {
  rp?: OptRp;
  user?: OptUser;
  challenge?: string;
  pubKeyCredParams?: OptParam[];
  timeout?: number;
  attestation?: string;
  authenticatorSelection?: OptSelection;
  excludeCredentials?: OptDescriptor[];
}

interface OptRoot {
  publicKey?: OptPublicKey;
}

function decodeBase64Url(input: string): Uint8Array {
  let s: string = input.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4 !== 0) {
    s += '=';
  }
  return new util.Base64Helper().decodeSync(s, util.Type.BASIC);
}

function encodeBase64Url(data: Uint8Array): string {
  const s: string = new util.Base64Helper().encodeToStringSync(data, util.Type.BASIC);
  return s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function encodeBase64(data: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(data, util.Type.BASIC);
}

function decodeBase64ToString(input: string): string {
  const bytes: Uint8Array = new util.Base64Helper().decodeSync(input, util.Type.BASIC);
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

function mapAlgorithm(alg: number): fido2.Algorithm | undefined {
  switch (alg) {
    case fido2.Algorithm.ES256:
      return fido2.Algorithm.ES256;
    case fido2.Algorithm.ES384:
      return fido2.Algorithm.ES384;
    case fido2.Algorithm.ES512:
      return fido2.Algorithm.ES512;
    case fido2.Algorithm.RS256:
      return fido2.Algorithm.RS256;
    case fido2.Algorithm.RS384:
      return fido2.Algorithm.RS384;
    case fido2.Algorithm.RS512:
      return fido2.Algorithm.RS512;
    case fido2.Algorithm.PS256:
      return fido2.Algorithm.PS256;
    case fido2.Algorithm.PS384:
      return fido2.Algorithm.PS384;
    case fido2.Algorithm.PS512:
      return fido2.Algorithm.PS512;
    default:
      return undefined;
  }
}

function mapUserVerification(value: string | undefined): fido2.UserVerificationRequirement {
  if (value === 'discouraged') {
    return fido2.UserVerificationRequirement.DISCOURAGED;
  }
  if (value === 'preferred') {
    return fido2.UserVerificationRequirement.PREFERRED;
  }
  return fido2.UserVerificationRequirement.REQUIRED;
}

function mapAttestation(value: string | undefined): fido2.AttestationConveyancePreference {
  if (value === 'direct') {
    return fido2.AttestationConveyancePreference.DIRECT;
  }
  if (value === 'indirect') {
    return fido2.AttestationConveyancePreference.INDIRECT;
  }
  if (value === 'enterprise') {
    return fido2.AttestationConveyancePreference.ENTERPRISE;
  }
  return fido2.AttestationConveyancePreference.NONE;
}

function failure(code: number, msg: string): string {
  const cancelled: boolean = (code === ERR_USER_ABORT || code === ERR_USER_REJECT);
  return JSON.stringify({ ok: false, code: code, cancelled: cancelled, msg: msg });
}

function messageForCode(code: number, fallback: string): string {
  if (code === ERR_NOT_SUPPORTED || code === ERR_DEVICE_TYPE) {
    return 'Passkeys are not supported on this device.';
  }
  if (code === ERR_CREDENTIAL_LIMIT) {
    return 'The maximum number of passkeys on this device has been reached.';
  }
  if (code === ERR_USER_ABORT || code === ERR_USER_REJECT) {
    return 'Passkey creation was cancelled.';
  }
  return fallback.length > 0 ? fallback : ('Passkey creation failed (code=' + code + ').');
}

function buildCreationOptions(root: OptRoot): fido2.CredentialCreationOptions | undefined {
  const pk: OptPublicKey | undefined = root.publicKey;
  if (pk === undefined) {
    return undefined;
  }
  const rp: OptRp | undefined = pk.rp;
  const user: OptUser | undefined = pk.user;
  if (rp === undefined || user === undefined || pk.challenge === undefined || user.id === undefined) {
    return undefined;
  }
  const rpName: string = rp.name !== undefined ? rp.name : (rp.id !== undefined ? rp.id : 'Telegram');
  const userName: string = user.name !== undefined ? user.name : '';
  const displayName: string = user.displayName !== undefined ? user.displayName : userName;

  const params: fido2.PublicKeyCredentialParameters[] = [];
  const srcParams: OptParam[] = pk.pubKeyCredParams !== undefined ? pk.pubKeyCredParams : [];
  for (let i = 0; i < srcParams.length; i++) {
    const alg: number | undefined = srcParams[i].alg;
    if (alg === undefined) {
      continue;
    }
    const mapped: fido2.Algorithm | undefined = mapAlgorithm(alg);
    if (mapped !== undefined) {
      params.push({ type: fido2.PublicKeyCredentialType.PUBLIC_KEY, alg: mapped });
    }
  }
  if (params.length === 0) {
    // Apple platform provider registers ES256 only; use the same baseline when the server omits params.
    params.push({ type: fido2.PublicKeyCredentialType.PUBLIC_KEY, alg: fido2.Algorithm.ES256 });
  }

  const exclude: fido2.PublicKeyCredentialDescriptor[] = [];
  const srcExclude: OptDescriptor[] = pk.excludeCredentials !== undefined ? pk.excludeCredentials : [];
  for (let i = 0; i < srcExclude.length; i++) {
    const credId: string | undefined = srcExclude[i].id;
    if (credId === undefined || credId.length === 0) {
      continue;
    }
    exclude.push({ type: fido2.PublicKeyCredentialType.PUBLIC_KEY, id: decodeBase64Url(credId) });
  }

  const sel: OptSelection | undefined = pk.authenticatorSelection;
  const selection: fido2.AuthenticatorSelectionCriteria = {
    // iOS always uses the platform (on-device) authenticator for passkeys.
    authenticatorAttachment: fido2.AuthenticatorAttachment.PLATFORM,
    residentKey: (sel !== undefined && sel.residentKey !== undefined) ? sel.residentKey : 'required',
    requireResidentKey: (sel !== undefined && sel.requireResidentKey !== undefined) ? sel.requireResidentKey : true,
    userVerification: mapUserVerification(sel !== undefined ? sel.userVerification : undefined)
  };

  const publicKey: fido2.PublicKeyCredentialCreationOptions = {
    rp: { id: rp.id, name: rpName },
    user: { id: decodeBase64Url(user.id), name: userName, displayName: displayName },
    challenge: decodeBase64Url(pk.challenge),
    pubKeyCredParams: params,
    timeout: pk.timeout,
    excludeCredentials: exclude,
    authenticatorSelection: selection,
    attestation: mapAttestation(pk.attestation)
  };
  return { mediation: fido2.CredentialMediationRequirement.REQUIRED, publicKey: publicKey };
}

export function registerPasskey(): void {
  registerArkFunc(InteropMethod.PASSKEY_REGISTER, (argJson: string, onResult: (r: string) => void): void => {
    let options: fido2.CredentialCreationOptions | undefined = undefined;
    try {
      const a: PasskeyRegisterArgs = JSON.parse(argJson) as PasskeyRegisterArgs;
      const root: OptRoot = JSON.parse(decodeBase64ToString(a.optionsB64)) as OptRoot;
      options = buildCreationOptions(root);
    } catch (e) {
      onResult(failure(0, 'Invalid passkey registration options.'));
      return;
    }
    if (options === undefined) {
      onResult(failure(0, 'Invalid passkey registration options.'));
      return;
    }
    // Interop callbacks do not run inside an ArkUI component scope; use the UIAbilityContext
    // retained by EntryAbility.onCreate (same as ContactPickerImpl).
    const context = globalThis.abilityContext as common.UIAbilityContext;
    try {
      fido2.register(context, options).then((credential: fido2.PublicKeyAttestationCredential): void => {
        try {
          const credentialId: string = encodeBase64Url(credential.rawId);
          onResult(JSON.stringify({
            ok: true,
            id: credentialId,
            rawId: credentialId,
            clientDataB64: encodeBase64(credential.response.clientDataJson),
            attestationB64: encodeBase64(credential.response.attestationObject)
          }));
        } catch (e) {
          onResult(failure(0, 'Could not encode the passkey credential.'));
        }
      }).catch((e: BusinessError): void => {
        const code: number = (typeof e.code === 'number') ? e.code : 0;
        onResult(failure(code, messageForCode(code, (typeof e.message === 'string') ? e.message : '')));
      });
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      const code: number = (typeof be.code === 'number') ? be.code : 0;
      onResult(failure(code, messageForCode(code, (typeof be.message === 'string') ? be.message : '')));
    }
  });
}
