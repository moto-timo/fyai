// SPDX-License-Identifier: MIT
/*
 * The page's door to the app: choose or open a project. Each call is one
 * request to the main process, which opens the project in a window of its own.
 */

/* A CommonJS preload: Electron loads it before the page. */
/* eslint-disable @typescript-eslint/no-require-imports */
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('fyaiDesktop', {
	chooseProject: () => ipcRenderer.invoke('fyai:project-choose'),
	openProject: (dir) => ipcRenderer.invoke('fyai:project-open', dir),
	recentProjects: () => ipcRenderer.invoke('fyai:project-recent')
});
