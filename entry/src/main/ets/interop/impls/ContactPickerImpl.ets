// Permission-free system contact picker for normal HarmonyOS applications.
// API 10+ selectContacts presents system-owned UI and returns only contacts
// explicitly selected by the user.
import { registerArkFunc } from 'libohos_app_cangjie_entry.so';
import { InteropMethod } from '../InteropContract';
import contact from '@ohos.contact';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

class MultiContactSelectionOptions implements contact.ContactSelectionOptions {
  isMultiSelect: boolean = true;
}

class PickedContact {
  displayName: string = '';
  firstName: string = '';
  lastName: string = '';
  phoneNumber: string = '';
}

class ContactPickerResponse {
  ok: boolean = false;
  status: string = 'error';
  contacts: Array<PickedContact> = [];
}

interface AddContactArgs {
  firstName?: string;
  lastName?: string;
  phoneNumber?: string;
}

export function registerContactPicker(): void {
  registerArkFunc(InteropMethod.PICK_CONTACTS, (_argJson: string, onResult: (r: string) => void): void => {
    const options: MultiContactSelectionOptions = new MultiContactSelectionOptions();
    contact.selectContacts(options).then((contacts: Array<contact.Contact>): void => {
      const response: ContactPickerResponse = new ContactPickerResponse();
      response.ok = true;
      response.status = contacts.length === 0 ? 'cancelled' : 'picked';

      for (let i: number = 0; i < contacts.length; i++) {
        const source: contact.Contact = contacts[i];
        const picked: PickedContact = new PickedContact();
        if (source.name !== undefined) {
          picked.displayName = source.name.fullName;
          picked.firstName = source.name.givenName ?? '';
          picked.lastName = source.name.familyName ?? '';
        }
        if (source.phoneNumbers !== undefined && source.phoneNumbers.length > 0) {
          picked.phoneNumber = source.phoneNumbers[0].phoneNumber;
        }
        if (picked.displayName.length === 0) {
          picked.displayName = picked.phoneNumber;
        }
        if (picked.phoneNumber.length > 0) {
          response.contacts.push(picked);
        }
      }
      onResult(JSON.stringify(response));
    }).catch((): void => {
      onResult(JSON.stringify(new ContactPickerResponse()));
    });
  });

  registerArkFunc(InteropMethod.ADD_CONTACT_VIA_UI, (argJson: string, onResult: (r: string) => void): void => {
    let setupStage: string = 'parse';
    try {
      const args: AddContactArgs = JSON.parse(argJson) as AddContactArgs;
      const firstName: string = typeof args.firstName === 'string' ? args.firstName : '';
      const lastName: string = typeof args.lastName === 'string' ? args.lastName : '';
      const phoneNumber: string = typeof args.phoneNumber === 'string' ? args.phoneNumber : '';
      if (phoneNumber.length === 0) {
        onResult('{"ok":false,"status":"invalid"}');
        return;
      }

      setupStage = 'contact';
      const newContact: contact.Contact = new contact.Contact();
      setupStage = 'name';
      const name: contact.Name = {
        givenName: firstName,
        familyName: lastName,
        fullName: (firstName + ' ' + lastName).trim()
      };
      newContact.name = name;

      setupStage = 'phone';
      const number: contact.PhoneNumber = {
        phoneNumber: phoneNumber,
        labelId: contact.PhoneNumber.NUM_MOBILE
      };
      newContact.phoneNumbers = [number];

      // Interop callbacks do not run inside an ArkUI component scope. Calling
      // getContext() here can itself throw before a fallback is evaluated, so
      // use the UIAbilityContext retained by EntryAbility during onCreate.
      setupStage = 'context';
      const context = globalThis.abilityContext as common.UIAbilityContext;
      setupStage = 'launch';
      contact.addContactViaUI(context, newContact).then((contactId: number): void => {
        if (contactId === contact.Contact.INVALID_CONTACT_ID) {
          onResult('{"ok":false,"status":"cancelled"}');
        } else {
          onResult('{"ok":true,"status":"saved"}');
        }
      }).catch((e: Error): void => {
        hilog.error(
          0x0000,
          'ContactPicker',
          'addContactViaUI failed: %{public}s',
          JSON.stringify(e) ?? ''
        );
        onResult('{"ok":false,"status":"cancelled"}');
      });
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(
        0x0000,
        'ContactPicker',
        'addContactViaUI setup failed at %{public}s, code=%{public}d, message=%{public}s',
        setupStage,
        be.code,
        be.message
      );
      onResult('{"ok":false,"status":"error"}');
    }
  });
}
