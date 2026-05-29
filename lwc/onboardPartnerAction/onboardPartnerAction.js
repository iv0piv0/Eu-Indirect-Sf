import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import initOnboarding from '@salesforce/apex/PartnerOnboardingController.initOnboarding';

export default class OnboardPartnerAction extends LightningElement {
    @api recordId;
    @api async invoke() {
        console.log('invoke called, recordId:', this.recordId);
        try {
            const error = await initOnboarding({ caseId: this.recordId });
            if (error) {
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Onboarding Error',
                    message: error,
                    variant: 'error',
                    mode:    'sticky'
                }));
            } else {
                this.dispatchEvent(new ShowToastEvent({
                    title:   'Partner Onboarding Started',
                    message: 'Request sent to NCP. Check Case Logs for the response.',
                    variant: 'success',
                    mode:    'sticky'
                }));
            }
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Onboarding Error',
                message: e.body?.message || e.message || 'Unexpected error — check Execution Logs.',
                variant: 'error',
                mode:    'sticky'
            }));
        }
    }
}