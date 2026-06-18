const taskHud = document.getElementById('taskHud');
const taskText = document.getElementById('taskText');
const toggleKeyBadge = document.getElementById('toggleKeyBadge');

const dialogueBox = document.getElementById('dialogueBox');
const dialogueSpeaker = document.getElementById('dialogueSpeaker');
const dialogueText = document.getElementById('dialogueText');

window.addEventListener('message', (event) => {
    const data = event.data;

    if (data.action === 'showTask') {
        taskText.textContent = data.text;
        if (data.key) toggleKeyBadge.textContent = data.key;
        taskHud.classList.remove('hidden');
    } else if (data.action === 'hideTask') {
        taskHud.classList.add('hidden');
    } else if (data.action === 'setTaskVisibility') {
        taskHud.classList.toggle('hidden', !data.visible);
    } else if (data.action === 'showDialogue') {
        dialogueSpeaker.textContent = data.speaker || '';
        dialogueText.textContent = data.text || '';
        dialogueBox.classList.remove('hidden');
    } else if (data.action === 'hideDialogue') {
        dialogueBox.classList.add('hidden');
    }
});
