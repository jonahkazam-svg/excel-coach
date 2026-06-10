# Liquid Glass Snippets (snipzy.dev) — Verbatim Code Reference

Source: https://snipzy.dev — fetched 2026-06-10. Each section contains the verbatim HTML, CSS, and JS for one snippet.

Shared architecture across all snippets: a container with 4 stacked layers —
`.glass-filter` (z1, `backdrop-filter: blur(4px)` + `filter: url(#glass-distortion) saturate(120%) brightness(1.15)`),
`.glass-overlay` (z2, `background: var(--bg-color)`),
`.glass-specular` (z3, `box-shadow: inset 1px 1px 1px var(--highlight)`),
`.glass-content` (z4). All share the same SVG `#glass-distortion` filter (feTurbulence baseFrequency 0.008, 2 octaves; feDisplacementMap scale 77). Light mode: `--bg-color: rgba(255,255,255,0.25)`, `--highlight: rgba(255,255,255,0.75)`. Dark mode: `--bg-color: rgba(0,0,0,0.25)`, `--highlight: rgba(255,255,255,0.15)`. JS dynamic highlight = radial-gradient at cursor: `rgba(255,255,255,0.15) 0%, rgba(255,255,255,0.05) 30%, rgba(255,255,255,0) 60%`.

---

## CRD004 — Liquid Glass Card

URL: https://snipzy.dev/snippets/liquid-glass-card.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-card">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <h3>Liquid Glass Card</h3>
    <p>Modern glassmorphism with distortion effects</p>
  </div>
</div>
```

### CSS

```css
/* Glass Card Container */
.glass-card {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  
  position: relative;
  width: 300px;
  height: 200px;
  border-radius: 20px;
  overflow: hidden;
  box-shadow: 0 6px 24px rgba(0, 0, 0, 0.2);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-distortion-overlay {
  position: absolute;
  inset: 0;
  background: radial-gradient(circle at 20% 30%, rgba(255,255,255,0.05) 0%, transparent 80%),
              radial-gradient(circle at 80% 70%, rgba(255,255,255,0.05) 0%, transparent 80%);
  background-size: 300% 300%;
  animation: floatDistort 10s infinite ease-in-out;
  mix-blend-mode: overlay;
  z-index: 2;
  pointer-events: none;
}

@keyframes floatDistort {
  0% { background-position: 0% 0%; }
  50% { background-position: 100% 100%; }
  100% { background-position: 0% 0%; }
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  padding: 20px;
  color: var(--text);
  text-align: center;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  height: 100%;
}

.glass-content h3 {
  margin: 0 0 10px 0;
  font-size: 24px;
  font-weight: 600;
}

.glass-content p {
  margin: 0;
  opacity: 0.8;
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-card {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

```javascript
// Add mouse movement interactivity to glass elements
document.addEventListener('DOMContentLoaded', function() {
  // Get all glass elements
  const glassElements = document.querySelectorAll('.glass-card');
  
  // Add mousemove effect for each glass element
  glassElements.forEach(element => {
    element.addEventListener('mousemove', handleMouseMove);
    element.addEventListener('mouseleave', handleMouseLeave);
  });
  
  // Handle mouse movement over glass elements
  function handleMouseMove(e) {
    const rect = this.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    // Update filter turbulence based on mouse position
    const filter = this.querySelector('filter feDisplacementMap');
    if (filter) {
      const scaleX = (x / rect.width) * 100;
      const scaleY = (y / rect.height) * 100;
      filter.setAttribute('scale', Math.min(scaleX, scaleY));
    }
    
    // Add highlight effect
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = `radial-gradient(
        circle at ${x}px ${y}px,
        rgba(255,255,255,0.15) 0%,
        rgba(255,255,255,0.05) 30%,
        rgba(255,255,255,0) 60%
      )`;
    }
  }
  
  // Reset effects when mouse leaves
  function handleMouseLeave() {
    const filter = this.querySelector('filter feDisplacementMap');
    if (filter) {
      filter.setAttribute('scale', '77');
    }
    
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = 'none';
    }
  }
});
```

---

## BTN003 — Liquid Glass Button

URL: https://snipzy.dev/snippets/liquid-glass-button.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<button class="glass-button">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <span>Liquid Glass Button</span>
  </div>
</button>
```

### CSS

```css
/* Glass Button Container */
.glass-button {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  
  position: relative;
  padding: 12px 24px;
  border: none;
  border-radius: 12px;
  cursor: pointer;
  overflow: hidden;
  background: transparent;
  transition: transform 0.2s ease;
  outline: none;
}

.glass-button:hover {
  transform: scale(1.05);
}

.glass-button:active {
  transform: scale(0.95);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  color: var(--text);
  font-weight: 500;
  font-size: 16px;
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-button {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

```javascript
// Add mouse movement interactivity to glass button
document.addEventListener('DOMContentLoaded', function() {
  // Get all glass elements
  const glassElements = document.querySelectorAll('.glass-button');
  
  // Add mousemove effect for each glass element
  glassElements.forEach(element => {
    element.addEventListener('mousemove', handleMouseMove);
    element.addEventListener('mouseleave', handleMouseLeave);
  });
  
  // Handle mouse movement over glass elements
  function handleMouseMove(e) {
    const rect = this.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    
    // Add highlight effect
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = `radial-gradient(
        circle at ${x}px ${y}px,
        rgba(255,255,255,0.15) 0%,
        rgba(255,255,255,0.05) 30%,
        rgba(255,255,255,0) 60%
      )`;
    }
  }
  
  // Reset effects when mouse leaves
  function handleMouseLeave() {
    const filter = document.querySelector('#glass-distortion feDisplacementMap');
    if (filter) {
      filter.setAttribute('scale', '77');
    }
    
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = 'none';
    }
  }
});
```

---

## DRP001 — Liquid Glass Dropdown

URL: https://snipzy.dev/snippets/liquid-glass-dropdown.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-dropdown-list">
  <!-- Item 1 -->
  <div class="glass-dropdown">
    <input type="checkbox" id="dropdown1" class="dropdown-toggle">
    <label for="dropdown1" class="dropdown-header">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <span>Features</span>
        <svg class="dropdown-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
    </label>
    <div class="dropdown-content">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <ul>
          <li>Modern Design</li>
          <li>Smooth Animations</li>
          <li>Pure CSS</li>
          <li>Responsive Layout</li>
        </ul>
      </div>
    </div>
  </div>

  <!-- Item 2 -->
  <div class="glass-dropdown">
    <input type="checkbox" id="dropdown2" class="dropdown-toggle">
    <label for="dropdown2" class="dropdown-header">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <span>Documentation</span>
        <svg class="dropdown-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
    </label>
    <div class="dropdown-content">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <p>This is a pure CSS implementation of a glass-style dropdown/accordion. No JavaScript required!</p>
      </div>
    </div>
  </div>

  <!-- Item 3 -->
  <div class="glass-dropdown">
    <input type="checkbox" id="dropdown3" class="dropdown-toggle">
    <label for="dropdown3" class="dropdown-header">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <span>Support</span>
        <svg class="dropdown-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <path d="M19 9l-7 7-7-7"/>
        </svg>
      </div>
    </label>
    <div class="dropdown-content">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="glass-content">
        <p>Need help? Contact our support team for assistance.</p>
      </div>
    </div>
  </div>
</div>
```

### CSS

```css
/* Glass Dropdown List Container */
.glass-dropdown-list {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  
  display: flex;
  flex-direction: column;
  gap: 16px;
  width: 100%;
  max-width: 400px;
}

/* Glass Dropdown Item */
.glass-dropdown {
  position: relative;
}

/* Hide checkbox but keep it accessible */
.dropdown-toggle {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

/* Dropdown Header */
.dropdown-header {
  position: relative;
  display: block;
  border-radius: 12px;
  overflow: hidden;
  cursor: pointer;
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  padding: 16px;
  color: var(--text);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

/* Dropdown Arrow */
.dropdown-arrow {
  width: 20px;
  height: 20px;
  transition: transform 0.3s ease;
}

/* Dropdown Content */
.dropdown-content {
  position: relative;
  overflow: hidden;
  max-height: 0;
  transition: max-height 0.3s ease;
  border-radius: 12px;
  margin-top: 8px;
}

.dropdown-content .glass-content {
  padding: 0 16px;
  opacity: 0;
  transform: translateY(-10px);
  transition: all 0.3s ease;
}

/* Dropdown Open State */
.dropdown-toggle:checked ~ .dropdown-header .dropdown-arrow {
  transform: rotate(180deg);
}

.dropdown-toggle:checked ~ .dropdown-content {
  max-height: 200px;
}

.dropdown-toggle:checked ~ .dropdown-content .glass-content {
  padding: 16px;
  opacity: 1;
  transform: translateY(0);
}

/* Content Styling */
.dropdown-content ul {
  list-style: none;
  margin: 0;
  padding: 0;
}

.dropdown-content li {
  margin: 8px 0;
}

/* Hover Effects */
.dropdown-header:hover .glass-overlay {
  background: rgba(255, 255, 255, 0.3);
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-dropdown-list {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

No JavaScript required (uses CSS checkbox toggle pattern).

---

## FRM001 — Liquid Glass Form

URL: https://snipzy.dev/snippets/liquid-glass-form.html

### HTML

```html
<!-- Font Awesome Icons; Make sure to add it in the <head> tag -->
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">

<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-form">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <div class="form-container login active">
      <h3>Login</h3>
      <form>
        <div class="form-group">
          <i class="fas fa-envelope"></i>
          <input type="email" placeholder="Email" required>
        </div>
        <div class="form-group">
          <i class="fas fa-lock"></i>
          <input type="password" placeholder="Password" required>
        </div>
        <button type="submit">Sign In</button>
      </form>
      <p class="form-switch">Don't have an account? <a href="#" class="switch-to-register">Register</a></p>
    </div>
    
    <div class="form-container register">
      <h3>Register</h3>
      <form>
        <div class="form-group">
          <i class="fas fa-user"></i>
          <input type="text" placeholder="Username" required>
        </div>
        <div class="form-group">
          <i class="fas fa-envelope"></i>
          <input type="email" placeholder="Email" required>
        </div>
        <div class="form-group">
          <i class="fas fa-lock"></i>
          <input type="password" placeholder="Password" required>
        </div>
        <div class="form-group">
          <i class="fas fa-lock"></i>
          <input type="password" placeholder="Confirm Password" required>
        </div>
        <button type="submit">Sign Up</button>
      </form>
      <p class="form-switch">Already have an account? <a href="#" class="switch-to-login">Login</a></p>
    </div>
  </div>
</div>
```

### CSS

```css
.glass-form {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  --input-bg: rgba(255, 255, 255, 0.1);
  --input-border: rgba(255, 255, 255, 0.2);
  --input-focus: rgba(255, 255, 255, 0.3);
  
  position: relative;
  width: 400px;
  min-height: 450px;
  border-radius: 20px;
  overflow: hidden;
  box-shadow: 0 6px 24px rgba(0, 0, 0, 0.2);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  padding: 30px;
  color: var(--text);
  height: 100%;
}

.form-container {
  display: none;
  opacity: 0;
  transform: translateX(20px);
  transition: opacity 0.3s ease, transform 0.3s ease;
}

.form-container.active {
  display: block;
  opacity: 1;
  transform: translateX(0);
}

.form-container h3 {
  margin: 0 0 20px 0;
  font-size: 28px;
  font-weight: 600;
  text-align: center;
}

.form-group {
  position: relative;
  margin-bottom: 20px;
}

.form-group i {
  position: absolute;
  left: 15px;
  top: 50%;
  transform: translateY(-50%);
  color: var(--text);
  opacity: 0.8;
}

.form-group input {
  width: 100%;
  padding: 12px 15px 12px 45px;
  background: var(--input-bg);
  border: 1px solid var(--input-border);
  border-radius: 10px;
  color: var(--text);
  font-size: 16px;
  transition: border-color 0.3s ease, background 0.3s ease;
}

.form-group input:focus {
  outline: none;
  background: var(--input-focus);
  border-color: var(--highlight);
}

.form-group input::placeholder {
  color: rgba(255, 255, 255, 0.6);
}

button[type="submit"] {
  width: 100%;
  padding: 12px;
  background: rgba(255, 255, 255, 0.2);
  border: 1px solid rgba(255, 255, 255, 0.3);
  border-radius: 10px;
  color: var(--text);
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.3s ease;
  margin-top: 10px;
}

button[type="submit"]:hover {
  background: rgba(255, 255, 255, 0.3);
  border-color: rgba(255, 255, 255, 0.4);
}

.form-switch {
  text-align: center;
  margin-top: 20px;
  font-size: 14px;
  opacity: 0.8;
}

.form-switch a {
  color: var(--text);
  text-decoration: none;
  font-weight: 600;
  opacity: 1;
}

.form-switch a:hover {
  text-decoration: underline;
}

@media (prefers-color-scheme: dark) {
  .glass-form {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
    --input-bg: rgba(0, 0, 0, 0.2);
    --input-border: rgba(255, 255, 255, 0.1);
    --input-focus: rgba(0, 0, 0, 0.3);
  }
}
```

### JavaScript

```javascript
document.addEventListener('DOMContentLoaded', function() {
  // Get all glass form elements
  const glassElements = document.querySelectorAll('.glass-form');
  const switchToRegister = document.querySelector('.switch-to-register');
  const switchToLogin = document.querySelector('.switch-to-login');
  const loginForm = document.querySelector('.form-container.login');
  const registerForm = document.querySelector('.form-container.register');
  
  // Add mousemove effect for each glass element
  glassElements.forEach(element => {
    element.addEventListener('mousemove', handleMouseMove);
    element.addEventListener('mouseleave', handleMouseLeave);
  });
  
  // Form switch event listeners
  if (switchToRegister && switchToLogin && loginForm && registerForm) {
    switchToRegister.addEventListener('click', (e) => {
      e.preventDefault();
      loginForm.style.opacity = '0';
      loginForm.style.transform = 'translateX(-20px)';
      
      setTimeout(() => {
        loginForm.classList.remove('active');
        registerForm.classList.add('active');
        
        setTimeout(() => {
          registerForm.style.opacity = '1';
          registerForm.style.transform = 'translateX(0)';
        }, 50);
      }, 300);
    });
    
    switchToLogin.addEventListener('click', (e) => {
      e.preventDefault();
      registerForm.style.opacity = '0';
      registerForm.style.transform = 'translateX(-20px)';
      
      setTimeout(() => {
        registerForm.classList.remove('active');
        loginForm.classList.add('active');
        
        setTimeout(() => {
          loginForm.style.opacity = '1';
          loginForm.style.transform = 'translateX(0)';
        }, 50);
      }, 300);
    });
  }
  
  // Handle mouse movement over glass elements
  function handleMouseMove(e) {
    const rect = this.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    // Add highlight effect
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = `radial-gradient(
        circle at ${x}px ${y}px,
        rgba(255,255,255,0.15) 0%,
        rgba(255,255,255,0.05) 30%,
        rgba(255,255,255,0) 60%
      )`;
    }
  }
  
  // Reset effects when mouse leaves
  function handleMouseLeave() {
    const filter = document.querySelector('#glass-distortion feDisplacementMap');
    if (filter) {
      filter.setAttribute('scale', '77');
    }
    
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = 'none';
    }
  }
  
  // Form validation and submission handling
  const forms = document.querySelectorAll('.glass-form form');
  forms.forEach(form => {
    const inputs = form.querySelectorAll('input');
    
    // Add input validation styles
    inputs.forEach(input => {
      input.addEventListener('invalid', function() {
        this.classList.add('error');
      });
      
      input.addEventListener('input', function() {
        if (this.validity.valid) {
          this.classList.remove('error');
        }
      });
    });
    
    // Handle form submission
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      
      // Get form data
      const formData = new FormData(form);
      const data = Object.fromEntries(formData.entries());
      
      // Simple validation for password match in register form
      if (form.closest('.register')) {
        const password = data.password;
        const confirmPassword = data['confirm-password'];
        
        if (password !== confirmPassword) {
          alert('Passwords do not match!');
          return;
        }
      }
      
      // Here you would typically send the data to your server
      console.log('Form submitted:', data);
      
      // Show success state
      const submitBtn = form.querySelector('button[type="submit"]');
      const originalText = submitBtn.textContent;
      submitBtn.textContent = 'Success!';
      submitBtn.classList.add('success');
      
      setTimeout(() => {
        submitBtn.textContent = originalText;
        submitBtn.classList.remove('success');
        form.reset();
      }, 2000);
    });
  });

  // Initialize code blocks for the snippet preview
  initializeCodeBlocks();
});

// Function to initialize code blocks
function initializeCodeBlocks() {
  const htmlCode = document.getElementById('html-code');
  const cssCode = document.getElementById('css-code');
  const jsCode = document.getElementById('js-code');

  // Add copy functionality to code blocks
  document.querySelectorAll('.copy-button').forEach(button => {
    button.addEventListener('click', () => {
      const targetId = button.getAttribute('data-target');
      const codeBlock = document.getElementById(targetId);
      if (codeBlock) {
        navigator.clipboard.writeText(codeBlock.textContent).then(() => {
          button.innerHTML = ' Copied!';
          setTimeout(() => {
            button.innerHTML = ' Copy';
          }, 2000);
        });
      }
    });
  });
}
```

---

## ICO001 — Liquid Glass Icons

URL: https://snipzy.dev/snippets/liquid-glass-icons.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-icons-grid">
  <!-- Home Icon -->
  <div class="glass-icon">
    <div class="glass-filter"></div>
    <div class="glass-overlay"></div>
    <div class="glass-specular"></div>
    <div class="glass-content">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/></svg>
    </div>
  </div>

  <!-- Settings Icon -->
  <div class="glass-icon">
    <div class="glass-filter"></div>
    <div class="glass-overlay"></div>
    <div class="glass-specular"></div>
    <div class="glass-content">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 110-4m0 4v2m0-6V4"/></svg>
    </div>
  </div>

  <!-- User Icon -->
  <div class="glass-icon">
    <div class="glass-filter"></div>
    <div class="glass-overlay"></div>
    <div class="glass-specular"></div>
    <div class="glass-content">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/></svg>
    </div>
  </div>

  <!-- Bell Icon -->
  <div class="glass-icon">
    <div class="glass-filter"></div>
    <div class="glass-overlay"></div>
    <div class="glass-specular"></div>
    <div class="glass-content">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/></svg>
    </div>
  </div>
</div>
```

### CSS

```css
/* Glass Icons Grid */
.glass-icons-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(64px, 1fr));
  gap: 24px;
  max-width: 400px;
  margin: 0 auto;
}

.glass-icon {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --icon-color: #ffffff;
  --icon-size: 64px;
  
  position: relative;
  width: var(--icon-size);
  height: var(--icon-size);
  border-radius: 16px;
  overflow: hidden;
  background: transparent;
  cursor: pointer;
  transition: transform 0.2s ease;
}

.glass-icon:hover {
  transform: scale(1.1);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  width: 100%;
  height: 100%;
  display: flex;
  justify-content: center;
  align-items: center;
}

.glass-content svg {
  width: 80%;
  height: 80%;
  color: var(--icon-color);
  transition: transform 0.2s ease;
}

.glass-icon:hover .glass-content svg {
  transform: scale(0.9);
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-icon {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

None provided on the source page.

---

## NAV002 — Liquid Glass Navigation

URL: https://snipzy.dev/snippets/liquid-glass-nav.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<nav class="glass-nav">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <ul class="nav-list">
      <li><a href="#" class="nav-item active">Home</a></li>
      <li><a href="#" class="nav-item">About</a></li>
      <li><a href="#" class="nav-item">Services</a></li>
      <li><a href="#" class="nav-item">Contact</a></li>
    </ul>
  </div>
</nav>
```

### CSS

```css
/* Glass Navigation Container */
.glass-nav {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  
  position: relative;
  width: 100%;
  max-width: 600px;
  border-radius: 12px;
  overflow: hidden;
  background: transparent;
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  padding: 16px;
}

.nav-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  justify-content: center;
  gap: 24px;
}

.nav-item {
  color: var(--text);
  text-decoration: none;
  font-weight: 500;
  font-size: 16px;
  padding: 8px 16px;
  border-radius: 8px;
  transition: background-color 0.2s ease;
}

.nav-item:hover {
  background-color: rgba(255, 255, 255, 0.1);
}

.nav-item.active {
  background-color: rgba(255, 255, 255, 0.2);
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-nav {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

```javascript
document.addEventListener('DOMContentLoaded', function() {

 // Add nav item click handler
  const navItems = document.querySelectorAll('.nav-item');
  navItems.forEach(item => {
    item.addEventListener('click', function(e) {
      e.preventDefault();
      navItems.forEach(navItem => navItem.classList.remove('active'));
      this.classList.add('active');
    });
  });
});
```

---

## SRH002 — Liquid Glass Search

URL: https://snipzy.dev/snippets/liquid-glass-search.html

### HTML

```html
<!-- Font Awesome Icons; Make sure to add it in the <head> tag -->
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">

<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-search">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <div class="search-container">
      <i class="fas fa-search search-icon"></i>
      <input type="text" placeholder="Search..." class="search-input">
      <button class="search-clear" aria-label="Clear search">
        <i class="fas fa-times"></i>
      </button>
    </div>
    <div class="search-suggestions">
      <div class="suggestion-group">
        <h4>Recent Searches</h4>
        <ul>
          <li><i class="fas fa-history"></i>Glass effect components</li>
          <li><i class="fas fa-history"></i>Modern UI design</li>
          <li><i class="fas fa-history"></i>CSS animations</li>
        </ul>
      </div>
    </div>
  </div>
</div>
```

### CSS

```css
/* Glass Navigation Container */
.glass-search {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  --input-bg: rgba(255, 255, 255, 0.1);
  --input-border: rgba(255, 255, 255, 0.2);
  --input-focus: rgba(255, 255, 255, 0.3);
  
  position: relative;
  width: 500px;
  border-radius: 20px;
  overflow: hidden;
  box-shadow: 0 6px 24px rgba(0, 0, 0, 0.2);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  color: var(--text);
}

/* Search Container */
.search-container {
  position: relative;
  padding: 20px;
  display: flex;
  align-items: center;
  transition: padding 0.4s cubic-bezier(0.4, 0, 0.2, 1);
}

.search-container.expanded {
  padding: 25px 20px;
}

.search-icon {
  position: absolute;
  left: 35px;
  font-size: 18px;
  color: var(--text);
  opacity: 0.8;
  pointer-events: none;
  transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
  transform-origin: center;
}

.search-container.expanded .search-icon {
  transform: scale(1.1);
  opacity: 1;
}

.search-input {
  width: 100%;
  padding: 12px 45px;
  background: var(--input-bg);
  border: 1px solid var(--input-border);
  border-radius: 12px;
  color: var(--text);
  font-size: 16px;
  transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
  will-change: transform, box-shadow, background;
}

.search-input:focus {
  outline: none;
  background: var(--input-focus);
  border-color: var(--highlight);
  transform: translateY(-2px);
  box-shadow: 0 8px 16px rgba(0, 0, 0, 0.1);
}

.search-input:focus + .search-icon {
  opacity: 1;
  transform: scale(1.1) translateY(-2px);
}

.search-input::placeholder {
  color: rgba(255, 255, 255, 0.6);
  transition: opacity 0.3s ease;
}

.search-input:focus::placeholder {
  opacity: 0.4;
}

.search-clear {
  position: absolute;
  right: 35px;
  background: none;
  border: none;
  color: var(--text);
  opacity: 0;
  cursor: pointer;
  font-size: 16px;
  transition: opacity 0.3s ease;
  padding: 5px;
  border-radius: 50%;
}

.search-clear:hover {
  background: rgba(255, 255, 255, 0.1);
}

.search-input:not(:placeholder-shown) + .search-icon + .search-clear {
  opacity: 0.7;
}

/* Search Suggestions */
.search-suggestions {
  padding: 0 20px 20px;
  max-height: 0;
  opacity: 0;
  overflow: hidden;
  transform: translateY(-10px);
  transition: all 0.5s cubic-bezier(0.4, 0, 0.2, 1);
  pointer-events: none;
}

.search-suggestions.active {
  max-height: 300px;
  opacity: 1;
  transform: translateY(0);
  pointer-events: auto;
}

.suggestion-group h4 {
  font-size: 14px;
  margin: 0 0 10px;
  opacity: 0.7;
  font-weight: 500;
}

.suggestion-group ul {
  list-style: none;
  padding: 0;
  margin: 0;
}

.suggestion-group li {
  padding: 8px 12px;
  border-radius: 8px;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 10px;
  transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
  opacity: 0;
  transform: translateX(-10px);
}

.search-suggestions.active .suggestion-group li {
  opacity: 1;
  transform: translateX(0);
}

.suggestion-group li:nth-child(1) { transition-delay: 0.1s; }
.suggestion-group li:nth-child(2) { transition-delay: 0.15s; }
.suggestion-group li:nth-child(3) { transition-delay: 0.2s; }

.suggestion-group li:hover {
  background: rgba(255, 255, 255, 0.1);
  transform: translateX(5px);
}

.suggestion-group li i {
  opacity: 0.7;
  font-size: 14px;
  transition: transform 0.3s ease;
}

.suggestion-group li:hover i {
  transform: scale(1.1);
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-search {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
    --input-bg: rgba(0, 0, 0, 0.2);
    --input-border: rgba(255, 255, 255, 0.1);
    --input-focus: rgba(0, 0, 0, 0.3);
  }
}
```

### JavaScript

```javascript
document.addEventListener('DOMContentLoaded', function() {
  // Get all glass search elements
  const glassElements = document.querySelectorAll('.glass-search');
  const searchInput = document.querySelector('.search-input');
  const searchClear = document.querySelector('.search-clear');
  const searchSuggestions = document.querySelector('.search-suggestions');
  
  // Add mousemove effect for each glass element
  glassElements.forEach(element => {
    element.addEventListener('mousemove', handleMouseMove);
    element.addEventListener('mouseleave', handleMouseLeave);
  });
  
  // Search input interactions
  if (searchInput && searchSuggestions) {
    searchInput.addEventListener('focus', () => {
      searchSuggestions.classList.add('active');
    });
    
    searchInput.addEventListener('blur', (e) => {
      // Only hide suggestions if we're not clicking inside them
      if (!e.relatedTarget || !e.relatedTarget.closest('.search-suggestions')) {
        setTimeout(() => {
          searchSuggestions.classList.remove('active');
        }, 200);
      }
    });
    
    searchInput.addEventListener('input', (e) => {
      const hasValue = e.target.value.length > 0;
      if (hasValue) {
        searchSuggestions.classList.add('active');
      }
    });
  }
  
  // Clear button functionality
  if (searchClear && searchInput) {
    searchClear.addEventListener('click', () => {
      searchInput.value = '';
      searchInput.focus();
      searchSuggestions.classList.remove('active');
    });
  }
  
  // Handle suggestion clicks
  const suggestions = document.querySelectorAll('.suggestion-group li');
  suggestions.forEach(suggestion => {
    suggestion.addEventListener('click', () => {
      if (searchInput) {
        searchInput.value = suggestion.textContent;
        searchSuggestions.classList.remove('active');
        searchInput.focus();
      }
    });
  });
  
  // Handle mouse movement over glass elements
  function handleMouseMove(e) {
    const rect = this.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    // Add highlight effect
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = `radial-gradient(
        circle at ${x}px ${y}px,
        rgba(255,255,255,0.15) 0%,
        rgba(255,255,255,0.05) 30%,
        rgba(255,255,255,0) 60%
      )`;
    }
  }
  
  // Reset effects when mouse leaves
  function handleMouseLeave() {
    const filter = document.querySelector('#glass-distortion feDisplacementMap');
    if (filter) {
      filter.setAttribute('scale', '77');
    }
    
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = 'none';
    }
  }
});
```

---

## SBR001 — Liquid Glass Sidebar

URL: https://snipzy.dev/snippets/liquid-glass-sidebar.html

### HTML

```html
<!-- Font Awesome Icons; Make sure to add it in the <head> tag -->
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">

<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-sidebar">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <div class="sidebar-header">
      <h3>Menu</h3>
    </div>
    <nav class="sidebar-nav">
      <a href="#" class="nav-item active">
        <i class="fas fa-home"></i>
        <span>Home</span>
      </a>
      <a href="#" class="nav-item">
        <i class="fas fa-user"></i>
        <span>Profile</span>
      </a>
      <a href="#" class="nav-item">
        <i class="fas fa-cog"></i>
        <span>Settings</span>
      </a>
      <a href="#" class="nav-item">
        <i class="fas fa-chart-bar"></i>
        <span>Analytics</span>
      </a>
      <a href="#" class="nav-item">
        <i class="fas fa-envelope"></i>
        <span>Messages</span>
      </a>
    </nav>
  </div>
</div>
```

### CSS

```css
/* Glass Sidebar Container */
.glass-sidebar {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  
  position: relative;
  width: 280px;
  height: 500px;
  border-radius: 20px;
  overflow: hidden;
  box-shadow: 0 6px 24px rgba(0, 0, 0, 0.2);
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  color: var(--text);
  height: 100%;
  display: flex;
  flex-direction: column;
}

.sidebar-header {
  padding: 20px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.sidebar-header h3 {
  margin: 0;
  font-size: 24px;
  font-weight: 600;
}

.sidebar-nav {
  padding: 20px 0;
  flex: 1;
}

.nav-item {
  display: flex;
  align-items: center;
  padding: 12px 20px;
  color: var(--text);
  text-decoration: none;
  transition: background-color 0.3s;
  gap: 12px;
  transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
}

.nav-item:hover,
.nav-item.active {
  background: rgba(255, 255, 255, 0.1);
}

.nav-item i {
  font-size: 18px;
  width: 24px;
  text-align: center;
}

.nav-item span {
  font-size: 16px;
  opacity: 0.9;
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-sidebar {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

```javascript
document.addEventListener('DOMContentLoaded', function() {
  // Get all glass elements
  const glassElements = document.querySelectorAll('.glass-sidebar');
  
  // Add mousemove effect for each glass element
  glassElements.forEach(element => {
    element.addEventListener('mousemove', handleMouseMove);
    element.addEventListener('mouseleave', handleMouseLeave);
  });
  
  // Handle mouse movement over glass elements
  function handleMouseMove(e) {
    const rect = this.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    // Update filter turbulence based on mouse position
    const filter = this.querySelector('filter feDisplacementMap');
    if (filter) {
      const scaleX = (x / rect.width) * 100;
      const scaleY = (y / rect.height) * 100;
      filter.setAttribute('scale', Math.min(scaleX, scaleY));
    }
    
    // Add highlight effect
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = `radial-gradient(
        circle at ${x}px ${y}px,
        rgba(255,255,255,0.15) 0%,
        rgba(255,255,255,0.05) 30%,
        rgba(255,255,255,0) 60%
      )`;
    }
  }
  
  // Reset effects when mouse leaves
  function handleMouseLeave() {
    const filter = this.querySelector('filter feDisplacementMap');
    if (filter) {
      filter.setAttribute('scale', '77');
    }
    
    const specular = this.querySelector('.glass-specular');
    if (specular) {
      specular.style.background = 'none';
    }
  }

  // Add nav item click handler
  const navItems = document.querySelectorAll('.nav-item');
  navItems.forEach(item => {
    item.addEventListener('click', function(e) {
      e.preventDefault();
      navItems.forEach(navItem => navItem.classList.remove('active'));
      this.classList.add('active');
    });
  });
});
```

---

## LDR003 — Liquid Glass Spinner

URL: https://snipzy.dev/snippets/liquid-glass-spinner.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-spinner">
  <div class="glass-filter"></div>
  <div class="glass-overlay"></div>
  <div class="glass-specular"></div>
  <div class="glass-content">
    <div class="spinner-ring"></div>
    <div class="spinner-core"></div>
  </div>
</div>
```

### CSS

```css
.glass-spinner {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --spinner-size: 80px;
  --ring-size: 64px;
  --core-size: 24px;
  position: relative;
  width: var(--spinner-size);
  height: var(--spinner-size);
  border-radius: 50%;
  overflow: hidden;
  background: transparent;
}

.glass-filter, .glass-overlay, .glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

.glass-content {
  position: relative;
  z-index: 4;
  width: 100%;
  height: 100%;
  display: flex;
  justify-content: center;
  align-items: center;
}

.spinner-ring {
  position: absolute;
  width: var(--ring-size);
  height: var(--ring-size);
  border: 2px solid transparent;
  border-top-color: rgba(255, 255, 255, 0.8);
  border-right-color: rgba(255, 255, 255, 0.6);
  border-radius: 50%;
  animation: spin 1s linear infinite;
}

.spinner-core {
  width: var(--core-size);
  height: var(--core-size);
  background: rgba(255, 255, 255, 0.9);
  border-radius: 50%;
  animation: pulse 1s ease-in-out infinite alternate;
}

@keyframes spin {
  from { transform: rotate(0deg); }
  to { transform: rotate(360deg); }
}

@keyframes pulse {
  from {
    transform: scale(0.8);
    opacity: 0.5;
  }
  to {
    transform: scale(1);
    opacity: 0.8;
  }
}

@media (prefers-color-scheme: dark) {
  .glass-spinner {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
}
```

### JavaScript

None provided on the source page (pure CSS animation).

---

## TGL001 — Liquid Glass Toggle

URL: https://snipzy.dev/snippets/liquid-glass-toggle.html

### HTML

```html
<!-- SVG Filter for Glass Distortion -->
<svg style="display: none">
  <filter id="glass-distortion">
    <feTurbulence type="turbulence" baseFrequency="0.008" numOctaves="2" result="noise" />
    <feDisplacementMap in="SourceGraphic" in2="noise" scale="77" />
  </filter>
</svg>

<div class="glass-toggle-group">
  <!-- Toggle 1 -->
  <label class="glass-toggle">
    <input type="checkbox" class="toggle-input">
    <div class="toggle-track">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="toggle-thumb">
        <div class="glass-filter"></div>
        <div class="glass-overlay"></div>
        <div class="glass-specular"></div>
      </div>
    </div>
    <span class="toggle-label">Dark Mode</span>
  </label>

  <!-- Toggle 2 -->
  <label class="glass-toggle">
    <input type="checkbox" class="toggle-input" checked>
    <div class="toggle-track">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="toggle-thumb">
        <div class="glass-filter"></div>
        <div class="glass-overlay"></div>
        <div class="glass-specular"></div>
      </div>
    </div>
    <span class="toggle-label">Notifications</span>
  </label>

  <!-- Toggle 3 -->
  <label class="glass-toggle">
    <input type="checkbox" class="toggle-input">
    <div class="toggle-track">
      <div class="glass-filter"></div>
      <div class="glass-overlay"></div>
      <div class="glass-specular"></div>
      <div class="toggle-thumb">
        <div class="glass-filter"></div>
        <div class="glass-overlay"></div>
        <div class="glass-specular"></div>
      </div>
    </div>
    <span class="toggle-label">Auto Update</span>
  </label>
</div>
```

### CSS

```css
/* Glass Toggle Group */
.glass-toggle-group {
  display: flex;
  flex-direction: column;
  gap: 20px;
  min-width: 200px;
}

/* Glass Toggle Container */
.glass-toggle {
  --bg-color: rgba(255, 255, 255, 0.25);
  --highlight: rgba(255, 255, 255, 0.75);
  --text: #ffffff;
  --track-width: 60px;
  --track-height: 32px;
  --thumb-size: 24px;
  
  display: flex;
  align-items: center;
  gap: 12px;
  cursor: pointer;
}

/* Hide checkbox but keep it accessible */
.toggle-input {
  position: absolute;
  opacity: 0;
  pointer-events: none;
}

/* Toggle Track */
.toggle-track {
  position: relative;
  width: var(--track-width);
  height: var(--track-height);
  border-radius: 16px;
  overflow: hidden;
}

.glass-filter,
.glass-overlay,
.glass-specular {
  position: absolute;
  inset: 0;
  border-radius: inherit;
}

.glass-filter {
  z-index: 1;
  backdrop-filter: blur(4px);
  filter: url(#glass-distortion) saturate(120%) brightness(1.15);
}

.glass-overlay {
  z-index: 2;
  background: var(--bg-color);
}

.glass-specular {
  z-index: 3;
  box-shadow: inset 1px 1px 1px var(--highlight);
}

/* Toggle Thumb */
.toggle-thumb {
  position: absolute;
  z-index: 4;
  top: 4px;
  left: 4px;
  width: var(--thumb-size);
  height: var(--thumb-size);
  border-radius: 50%;
  transition: transform 0.3s ease;
  overflow: hidden;
}

.toggle-thumb .glass-overlay {
  background: rgba(255, 255, 255, 0.9);
}

/* Toggle Label */
.toggle-label {
  color: var(--text);
  font-size: 16px;
  user-select: none;
}

/* Checked State */
.toggle-input:checked + .toggle-track .toggle-thumb {
  transform: translateX(calc(var(--track-width) - var(--thumb-size) - 8px));
}

.toggle-input:checked + .toggle-track .glass-overlay {
  background: rgba(255, 255, 255, 0.4);
}

/* Focus State */
.toggle-input:focus-visible + .toggle-track {
  outline: 2px solid rgba(255, 255, 255, 0.5);
  outline-offset: 2px;
}

/* Hover State */
.glass-toggle:hover .toggle-track .glass-overlay {
  background: rgba(255, 255, 255, 0.35);
}

/* Dark mode styles */
@media (prefers-color-scheme: dark) {
  .glass-toggle {
    --bg-color: rgba(0, 0, 0, 0.25);
    --highlight: rgba(255, 255, 255, 0.15);
  }
  
  .toggle-thumb .glass-overlay {
    background: rgba(255, 255, 255, 0.8);
  }
}
```

### JavaScript

None provided on the source page — relies on native HTML checkbox functionality for toggling behavior.
